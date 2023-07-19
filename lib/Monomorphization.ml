(* Copyright (c) INRIA and Microsoft Corporation. All rights reserved. *)
(* Licensed under the Apache 2.0 License. *)

(* Monomorphization of functions and data types. *)

open Ast
open PrintAst.Ops
open Helpers

module K = Constant

(* Monomorphization of data type definitions **********************************)

(* A whole-program map from type lids to their definitions. *)
let build_def_map files =
  build_map files (fun map -> function
    | DType (lid, flags, _, def) ->
        Hashtbl.add map lid (flags, def)
    | _ ->
        ()
  )



(* We visit type declarations in order to monomorphize parameterized type
 * declarations and insert forward declarations as needed. Consider, for
 * instance:
 *
 *   type linked_list = Nil | Cons of int * buffer linked_list
 *
 * We see this phase as a classic graph traversal where the nodes are pairs of
 * types and effective type arguments, and the edges are uses. The example above
 * is visited, then a forward declaration is inserted to break the cycle from
 * the node (linked_list, []) to itself. This gives:
 *
 *   type linked_list // a forward declaration
 *   type linked_list = Nil | Cons of int * buffer linked_list
 *
 * This will be turned into the following C code:
 *
 *   struct s;
 *   typedef struct s t;
 *   typedef struct s {
 *     int x;
 *     t *next;
 *   } t;
 *
 * We visit non-parameterized type declarations at declaration site.
 * However, parameterized declarations, such as the following, are visited at
 * use-site:
 *
 *   type linked_list a = | Nil | Cons: x:int -> buffer (linked_list a)
 *
 * This gives:
 *
 *   type linked_list_int;
 *   type linked_list_int = Nil | Cons of int * buffer linked_list_int
 *)
type node = lident * typ list
type color = Gray | Black

let monomorphize_data_types map = object(self)

  inherit [_] map as super

  (* Assigning a color to each node. *)
  val state = Hashtbl.create 41
  (* We view tuples as the application of a special lid to its arguments. *)
  (* We record pending declarations as we visit top-level declarations. *)
  val mutable pending = []
  (* Current file, for warning purposes. *)
  val mutable current_file = ""
  (* Possibly populated with something relevant *)
  val mutable best_hint: node * lident = (dummy_lid, []), dummy_lid
  (* For forward references, a map from lid to its pending monomorphizations
     (type arguments) *)
  val pending_monomorphizations = Hashtbl.create 41
  val seen_declarations = Hashtbl.create 41

  method sanity_check () =
    Hashtbl.iter (fun lid args ->
      KPrint.bprintf "Missing monomorphization: %a<%a>\n" plid lid ptyps args
    ) pending_monomorphizations;
    if Hashtbl.length pending_monomorphizations > 0 then
      Warn.fatal_error "Internal error: missing monomorphizations"

  (* Record a new declaration. *)
  method private record (d: decl) =
    if Drop.file current_file then
      Warn.(maybe_fatal_error ("", DropDeclaration (lid_of_decl d, current_file)));
    pending <- d :: pending

  (* Clear all the pending declarations. *)
  method private clear () =
    let r = List.rev pending in
    pending <- [];
    r

  (* This method produces a type that is *unsuitable* for further passes, since
     it breaks the invariant that type abbreviations are inlined away. It is,
     however, a good candidate for picking a suitable, auto-generated name while
     using existing, previously-picked abbreviations. NB: not doing so will
     generate type errors, see miTLS for a minimal testcase *)
  method pretty (t: typ) =
    (object
      inherit [_] map
      method! visit_TTuple () args =
        match Hashtbl.find state (tuple_lid, args) with
        | exception Not_found ->
            let args = List.map (self#visit_typ false) args in
            TTuple args
        | _, chosen_lid ->
            TQualified chosen_lid

      method! visit_TApp () lid args =
        match Hashtbl.find state (lid, args) with
        | exception Not_found ->
            let args = List.map (self#visit_typ false) args in
            TApp (lid, args)
        | _, chosen_lid ->
            TQualified chosen_lid
    end)#visit_typ () t

  (* Compute the name of a given node in the graph. *)
  method private lid_of (n: node) =
    if List.length (snd n) = 0 then
      fst n, []
    else if fst best_hint = n then
      snd best_hint, []
    else
      let lid, args = n in
      let doc = PPrint.(separate_map underscore PrintAst.print_typ (List.map self#pretty args)) in
      let name = fst lid, KPrint.bsprintf "%s__%a" (snd lid) PrintCommon.pdoc doc in
      if Options.debug "monomorphization" then
        KPrint.bprintf "No hint provided for %a\n  current best hint: %a -> %a\n  picking: %a\n"
          ptyp (TApp (lid, args))
          ptyp (TApp (fst (fst best_hint), snd (fst best_hint)))
          plid (snd best_hint)
          plid name;
      name, [ Common.AutoGenerated ]

  (* Prettifying the field names for n-uples. *)
  method private field_at i =
    match i with
    | 0 -> "fst"
    | 1 -> "snd"
    | 2 -> "thd"
    | _ -> Printf.sprintf "f%d" i

  (* Visit a given node in the graph, modifying [pending] to append in reverse
   * order declarations as they are needed, including that of the node we are
   * visiting. *)
  method private visit_node (under_ref: bool) (n: node) =
    let lid, args = n in
    (* White, gray or black? *)
    match Hashtbl.find state n with
    | exception Not_found ->
        if Options.debug "data-types-traversal" then
          KPrint.bprintf "visiting %a<%a>: Not_found\n" plid (fst n) ptyps (snd n);
        let chosen_lid, flag = self#lid_of n in
        if lid = tuple_lid then begin
          Hashtbl.add state n (Gray, chosen_lid);
          let args = List.map (self#visit_typ under_ref) args in
          (* For tuples, we immediately know how to generate a definition. *)
          let fields = List.mapi (fun i arg -> Some (self#field_at i), (arg, false)) args in
          self#record (DType (chosen_lid, [ Common.Private ] @ flag, 0, Flat fields));
          Hashtbl.replace state n (Black, chosen_lid)
        end else begin
          (* This specific node has not been visited yet. *)
          Hashtbl.add state n (Gray, chosen_lid);

          let subst fields = List.map (fun (field, (t, m)) ->
            field, (DeBruijn.subst_tn args t, m)
          ) fields in
          begin match Hashtbl.find map lid with
          | exception Not_found ->
              Hashtbl.replace state n (Black, chosen_lid)
          | flags, (Variant _ | Flat _) when under_ref && not (Hashtbl.mem seen_declarations lid) ->
              (* Because this looks up a definition in the global map, the
                 definitions are reordered according to the traversal order, which
                 is generally a good idea (we accept more programs!), EXCEPT
                 when the user relies on mutual recursion behind a reference
                 (pointer) type. In that case, following the type dependency graph is
                 generally not a good idea, since we may go from a valid
                 ordering to an invalid one (see tests/MutualStruct.fst). So,
                 the intent here (i.e., when under a ref type) is that:
                 - tuple types ALWAYS get monomorphized on-demand (see
                   above)
                 - abbreviations are fine and won't cause further issues
                 - data types, however, need to have their names allocated and a
                   forward reference inserted (TODO: at most once), then the
                   specific choice of type arguments need to be recorded as
                   something we want to visit later (once we're done with this
                   particular traversal)... *)
              if Options.debug "data-types-traversal" then
                KPrint.bprintf "DEFERRING %a<%a>\n" plid (fst n) ptyps (snd n);
              self#record (DType (chosen_lid, flags, 0, Forward));
              Hashtbl.add pending_monomorphizations (fst n) (snd n);
              Hashtbl.remove state n
          | flags, Variant branches ->
              let branches = List.map (fun (cons, fields) -> cons, subst fields) branches in
              let branches = self#visit_branches_t under_ref branches in
              self#record (DType (chosen_lid, flag @ flags, 0, Variant branches));
              Hashtbl.replace state n (Black, chosen_lid)
          | flags, Flat fields ->
              let fields = self#visit_fields_t_opt under_ref (subst fields) in
              self#record (DType (chosen_lid, flag @ flags, 0, Flat fields));
              Hashtbl.replace state n (Black, chosen_lid)
          | flags, Abbrev t ->
              let t = DeBruijn.subst_tn args t in
              let t = self#visit_typ under_ref t in
              self#record (DType (chosen_lid, flag @ flags, 0, Abbrev t));
              Hashtbl.replace state n (Black, chosen_lid)
          | _ ->
              Hashtbl.replace state n (Black, chosen_lid)
          end
        end;
        chosen_lid
    | Gray, chosen_lid ->
        if Options.debug "data-types-traversal" then
          KPrint.bprintf "visiting %a<%a>: Gray\n" plid (fst n) ptyps (snd n);
        begin match Hashtbl.find map lid with
        | exception Not_found ->
            ()
        | flags, _ ->
            self#record (DType (chosen_lid, flags, 0, Forward))
        end;
        chosen_lid
    | Black, chosen_lid ->
        if Options.debug "data-types-traversal" then
          KPrint.bprintf "visiting %a<%a>: Black\n" plid (fst n) ptyps (snd n);
        chosen_lid

  (* Top-level, non-parameterized declarations are root of our graph traversal.
   * This also visits, via occurrences in code, applications of parameterized
   * types. *)
  method! visit_file _ file =
    let name, decls = file in
    current_file <- name;
    name, KList.map_flatten (fun d ->
      if Options.debug "data-types-traversal" then
        KPrint.bprintf "decl %a\n" plid (lid_of_decl d);
      match d with
      | DType (lid, _, n, Abbrev (TTuple args)) when n = 0 && not (Hashtbl.mem state (tuple_lid, args)) ->
          Hashtbl.remove map lid;
          if Options.debug "monomorphization" then
            KPrint.bprintf "%a abbreviation for %a\n" plid lid ptyp (TApp (tuple_lid, args));
          best_hint <- (tuple_lid, args), lid;
          ignore (self#visit_node false (tuple_lid, args));
          Hashtbl.add seen_declarations lid ();
          self#clear ()

      | DType (lid, _, n, Abbrev (TApp (hd, args) as t)) when n = 0 && not (Hashtbl.mem state (hd, args)) ->
          (* We have not yet monomorphized this type, and conveniently, we have
             a type abbreviation that provides us with a name hint! We simply
             ditch the type abbreviation and replace it with a monomorphization
             of the same name. *)
          Hashtbl.remove map lid;
          if Options.debug "monomorphization" then
            KPrint.bprintf "%a abbreviation for %a\n" plid lid ptyp t;

          (* miTLS backwards-compat strikes again: if the type is about to be
             GC'd (i.e. automatically rewritten to be heap-allocated to e.g.
             support lists "trivially" at the expense of a run-time GC)... then
             we need to make sure the generated name refers to the GC'd type. So
             the monomorphized type will be named foobar_gc... *)
          let abbrev_for_gc_type = Hashtbl.mem map hd && List.mem Common.GcType (fst (Hashtbl.find map hd)) in

          if abbrev_for_gc_type then
            best_hint <- (hd, args), (fst lid, snd lid ^ "_gc")
          else
            best_hint <- (hd, args), lid;

          ignore (self#visit_node false (hd, args));

          (* And a type abbreviation will automatically be rewritten (see
             GcTypes) into `typedef foobar foobar_gc *`. And mitlsffi.ci will be
             happy. *)
          if abbrev_for_gc_type then
            self#record (DType (lid, [], 0, Abbrev (TQualified (fst lid, snd lid ^ "_gc"))));

          Hashtbl.add seen_declarations lid ();
          self#clear ()

      | DType (lid, _, n, _) when n > 0 ->
          (* The type itself cannot be monomorphized, but we may have seen in
             the past monomorphic instances of this type that we ought to
             generate. *)
          List.iter (fun args ->
            ignore (self#visit_node false (lid, args));
            Hashtbl.remove pending_monomorphizations lid
          ) (Hashtbl.find_all pending_monomorphizations lid);

          Hashtbl.add seen_declarations lid ();
          self#clear ()

      | DType (lid, _, n, (Flat _ | Variant _ | Abbrev _)) ->
          (* Re-inserted by visit_node... don't insert twice. *)
          assert (n = 0);
          (* FIXME: the logic here is quite twisted... it should be simplified. My
             understanding is we want to BOTH visit the body of the type in case
             it recursively needs to trigger monomorphizations, and
             side-effectfully register the type as visited in our map for
             further uses (but why?). *)
          ignore (self#visit_decl false d);
          ignore (self#visit_node false (lid, []));
          Hashtbl.add seen_declarations lid ();
          self#clear ()

      | _ ->
          (* An actual run-time definition, needs to be retained. *)
          let d = self#visit_decl false d in
          Hashtbl.add seen_declarations (lid_of_decl d) ();
          self#clear () @ [ d ]
    ) decls

  method! visit_DType env name flags n d =
    if n > 0 then
      assert false
    else
      super#visit_DType env name flags n d

  method! visit_ETuple under_ref es =
    EFlat (List.mapi (fun i e -> Some (self#field_at i), self#visit_expr under_ref e) es)

  method! visit_PTuple under_ref pats =
    PRecord (List.mapi (fun i p -> self#field_at i, self#visit_pattern under_ref p) pats)

  method! visit_TTuple under_ref ts =
    TQualified (self#visit_node under_ref (tuple_lid, ts))

  method! visit_TQualified under_ref lid =
    TQualified (self#visit_node under_ref (lid, []))

  method! visit_TApp under_ref lid ts =
    TQualified (self#visit_node under_ref (lid, ts))

  method! visit_TBuf _ t const =
    TBuf (self#visit_typ true t, const)
end

let datatypes files =
  let map = build_def_map files in
  let o = monomorphize_data_types map in
  let files = o#visit_files false files in
  (* o#sanity_check (); *)
  files


(* Type monomorphization of functions. ****************************************)

(* JP: TODO: share the functionality with type monomorphization... the call to
 * Hashtbl.find is in the visitor but the Gen functionality is clearly
 * outside... sigh. *)
module Gen = struct
  let generated_lids = Hashtbl.create 41
  let pending_defs = ref []

  let gen_lid lid ts =
    let doc =
      let open PPrint in
      let open PrintAst in
      separate_map underscore print_typ ts
    in
    fst lid, snd lid ^ KPrint.bsprintf "__%a" PrintCommon.pdoc doc

  let register_def current_file original_lid ts lid def =
    Hashtbl.add generated_lids (original_lid, ts) lid;
    let d = def () in
    if Drop.file current_file then
      Warn.(maybe_fatal_error ("", DropDeclaration (lid_of_decl d, current_file)));
    pending_defs := d :: !pending_defs;
    lid

  let clear () =
    let r = List.rev !pending_defs in
    pending_defs := [];
    r
end


(* This follows the same structure as for data types, with a whole-program from
 * function & global lids to their respective definitions. Every type
 * application (caught via the visitor) generates an instance. *)
let functions files =
  let map = Helpers.build_map files (fun map -> function
    | DFunction (cc, flags, n, t, name, b, body) ->
        if n > 0 then
          Hashtbl.add map name (`Function (cc, flags, n, t, name, b, body))
    | DGlobal (flags, name, n, t, body) ->
        if n > 0 then
          Hashtbl.add map name (`Global (flags, name, n, t, body))
    | _ ->
        ()
  ) in

  let monomorphize = object(self)

    inherit [_] map

    (* Current file, for warning purposes. *)
    val mutable current_file = ""

    method! visit_file _ file =
      let file_name, decls = file in
      current_file <- file_name;
      file_name, KList.map_flatten (function
        | DFunction (cc, flags, n, ret, name, binders, body) ->
            if Hashtbl.mem map name then
              []
            else
              let d = DFunction (cc, flags, n, ret, name, binders, self#visit_expr_w () body) in
              assert (n = 0);
              Gen.clear () @ [ d ]
        | DGlobal (flags, name, n, t, body) ->
            if Hashtbl.mem map name then
              []
            else
              let d = DGlobal (flags, name, n, t, self#visit_expr_w () body) in
              assert (n = 0);
              Gen.clear () @ [ d ]
        | d ->
            [ d ]
      ) decls

    method! visit_ETApp env e ts =
      match e.node with
      | EQualified lid ->
          begin try
            (* Already monomorphized? *)
            EQualified (Hashtbl.find Gen.generated_lids (lid, ts))
          with Not_found ->
            match Hashtbl.find map lid with
            | exception Not_found ->
                (* External function. Bail. *)
                (self#visit_expr env e).node
            | `Function (cc, flags, n, ret, name, binders, body) ->
                (* Need to generate a new instance. *)
                if n <> List.length ts then begin
                  KPrint.bprintf "%a is not fully type-applied!\n" plid lid;
                  (self#visit_expr env e).node
                end else
                  (* The thunk allows registering the name before visiting the
                   * body, for polymorphic recursive functions. *)
                  let name = Gen.gen_lid name ts in
                  let def () =
                    let ret = DeBruijn.subst_tn ts ret in
                    let binders = List.map (fun { node; typ } ->
                      { node; typ = DeBruijn.subst_tn ts typ }
                    ) binders in
                    let body = DeBruijn.subst_ten ts body in
                    let body = self#visit_expr env body in
                    DFunction (cc, flags, 0, ret, name, binders, body)
                  in
                  EQualified (Gen.register_def current_file lid ts name def)

            | `Global (flags, name, n, t, body) ->
                if n <> List.length ts then begin
                  KPrint.bprintf "%a is not fully type-applied!\n" plid lid;
                  (self#visit_expr env e).node
                end else
                  let name = Gen.gen_lid name ts in
                  let def () =
                    let t = DeBruijn.subst_tn ts t in
                    let body = DeBruijn.subst_ten ts body in
                    let body = self#visit_expr env body in
                    DGlobal (flags, name, 0, t, body)
                  in
                  EQualified (Gen.register_def current_file lid ts name def)

          end

      | EOp ((K.Eq | K.Neq), _) ->
          assert false

      | EOp (_, _) ->
         (self#visit_expr env e).node

      | _ ->
          KPrint.bprintf "%a is not an lid in the type application\n" pexpr e;
          (self#visit_expr env e).node

  end in

  monomorphize#visit_files () files


let equalities files =

  let types_map = Helpers.build_map files (fun map d ->
    match d with
    | DType (lid, _, _, d) -> Hashtbl.add map lid d
    | _ -> ()
  ) in

  (* I first tried carrying over the map from DataTypes to here, but this map is
     invalidated by the call to GcTypes which results in stale data type definitions
     being left in the map. So, we anticipate a little bit on the result of
     DataTypes.everything here, and just replicate the logic to determine
     whether this is going to end up being an enum or not. *)
  let enum_eventually lid =
    match Hashtbl.find types_map lid with
    | exception Not_found ->
        false
    | Variant branches ->
        List.for_all (fun (_, fields) -> List.length fields = 0) branches
    | _ ->
        false
  in

  let monomorphize = object(self)

    inherit [_] map as _super

    val mutable current_file = ""
    val mutable has_cycle = false

    method! visit_file env file =
      let file_name, decls = file in
      current_file <- file_name;
      file_name, KList.map_flatten (fun d ->
        let d = self#visit_decl env d in
        let equalities = Gen.clear () in
        let equalities = List.map (function
          | DFunction (cc, flags, n, ret, name, binders, body) ->
              (* This is a highly conservative criterion that is triggered by
               * any recursive type; we could be smarter and only break the
               * cycles by marking ONE declaration public.  *)
              let flags =
                if has_cycle then
                  List.filter ((<>) Common.Private) flags
                else
                  flags
              in
              DFunction (cc, flags, n, ret, name, binders, body)
          | d ->
              d
        ) equalities in
        has_cycle <- false;
        equalities @ [ d ]
      ) decls

    method private maybe_by_addr head x y =
      let t_op, x, y =
        match x.typ with
        | TQualified lid when Hashtbl.find_opt types_map lid = Some Forward ->
            let t = TBuf (x.typ, true) in
            TArrow (t, TArrow (t, TBool)), with_type t (EAddrOf x), with_type t (EAddrOf y)
        | _ ->
            let t = x.typ in
            TArrow (t, TArrow (t, TBool)), x, y
      in
      EApp (with_type t_op head, [x;y])

    (* For type [t] and either [op = Eq] or [op = Neq], generate a recursive
     * equality predicate that implements F*'s structural equality. *)
    method private generate_equality t op =
      (* A set of helpers use for generating abstract syntax. *)
      let eq_lid = match op with
        | K.PEq -> [], "__eq"
        | K.PNeq -> [], "__neq"
      in
      let instance_lid = Gen.gen_lid eq_lid [ t ] in
      let x = fresh_binder "x" t in
      let y = fresh_binder "y" t in

      (* Generate an external to stand in for a user-provided equality operator
         for an external type. *)
      let gen_poly ?(pointer=false) () =
        let t' = if pointer then TBuf (t, true) else t in
        let eq_typ' = TArrow (t', TArrow (t', TBool)) in
        match op with
        | K.PNeq ->
            (* let __neq__t x y = not (__eq__t x y) *)
            let def () =
              let body = mk_not (with_type TBool (
                EApp (with_type eq_typ' (self#generate_equality t K.PEq), [
                  with_type t' (EBound 0); with_type t' (EBound 1) ])))
              in
              DFunction (None, [ Common.Private ], 0, TBool, instance_lid, [ y; x ], body)
            in
            EQualified (Gen.register_def current_file eq_lid [ t ] instance_lid def)
        | K.PEq ->
            (* assume val __eq__t: t -> t -> bool *)
            let def () = DExternal (None, [], 0, instance_lid, eq_typ', [ "x"; "y" ]) in
            EQualified (Gen.register_def current_file eq_lid [ t ] instance_lid def)
      in


      match t with
      | TQualified ([ "Prims" ], ("int" | "nat" | "pos")) ->
          EOp (K.op_of_poly_comp op, K.CInt)

      | TQualified lid when enum_eventually lid ->
          EPolyComp (op, t)

      | TInt w ->
          EOp (K.op_of_poly_comp op, w)

      | TBool ->
          EOp (K.op_of_poly_comp op, K.Bool)

      | TBuf _ ->
          (* 20210205: I don't think this is allowed anymore, at all. Maybe with
             Steel we'll have raw pointer comparison? Leaving it here just in
             case. *)
          EPolyComp (op, t)

      | TQualified lid when Hashtbl.mem types_map lid ->
          begin try
            (* Already monomorphized? *)
            let existing_lid = Hashtbl.find Gen.generated_lids (eq_lid, [ t ]) in
            let is_cycle = List.exists (fun d -> lid_of_decl d = existing_lid) !Gen.pending_defs in
            if is_cycle then
              has_cycle <- true;
            EQualified existing_lid
          with Not_found ->
            let mk_conj_or_disj es =
              match op with
              | K.PEq -> List.fold_left mk_and etrue es
              | K.PNeq -> List.fold_left mk_or efalse es
            in
            let mk_rec_equality t e1 e2 =
              match t with
              | TUnit ->
                  (* This phase occurs after monomorphization, but before the
                   * elimination of unit arguments to data constructors. (Could
                   * we move it to occur after that? Unclear.) As such, we are
                   * sometimes tasked we generating recursive equality
                   * predicates for units. [generate_equality] can only return a
                   * function, so we intercept the recursive call here, and
                   * insert "true" for units, rather than going through the
                   * fallback that generates an "extern" call. *)
                  with_type TBool (EBool true)
              | _ ->
                  with_type TBool (
                    self#maybe_by_addr (self#generate_equality t op) (with_type t e1) (with_type t e2))
            in
            match Hashtbl.find types_map lid with
            | Abbrev _ | Enum _ | Union _ as e ->
                KPrint.bprintf "Error: did not expect %a\n" ppdef e;
                (* No abbreviations (this runs after inline_type abbrevs).
                 * No Enum / Union / Forward (this runs before data types). *)
                assert false

            | Forward ->
                (* Happens when an abstract external type is marked as
                   CAbstractStruct. TODO this is really unpleasant because
                   without the annotation, the type wouldn't be generated at all
                   and would end up "implicitly" external, as in the final case
                   below. *)
                gen_poly ~pointer:true ()

            | Flat fields ->
                (* Either a conjunction of equalities, or a disjunction of inequalities. *)
                let def () =
                  let sub_equalities = List.map (fun (f, (t_field, _)) ->
                    let f = Option.must f in
                    (* __eq__ x.f y.f *)
                    mk_rec_equality t_field
                      (EField (with_type t (EBound 0), f))
                      (EField (with_type t (EBound 1), f))
                  ) fields in
                  DFunction (None, [ Common.Private ], 0, TBool, instance_lid, [ y; x ],
                    mk_conj_or_disj sub_equalities)
                in
                EQualified (Gen.register_def current_file eq_lid [ t ] instance_lid def)
            | Variant branches ->
                let def () =
                  let fail_case = match op with
                    | K.PEq -> efalse
                    | K.PNeq -> etrue
                  in
                  (* let __eq__typ y x = *)
                  DFunction (None, [ Common.Private ], 0, TBool, instance_lid, [ y; x ],
                    (* match *)
                    with_type TBool (EMatch (
                      (* x with *)
                      with_type t (EBound 0),
                      List.map (fun (cons, fields) ->
                        let n = List.length fields in
                        let binders_x = List.map (fun (f, (t, _)) ->
                          fresh_binder (KPrint.bsprintf "x_%s" f) t
                        ) fields in
                        (* \. xn ... x0. *)
                        List.rev binders_x,
                        (* A x0 ... xn -> *)
                        with_type t (PCons (cons, List.mapi (fun i (_, (t_f, _)) ->
                          with_type t_f (PBound i)) fields)),
                        (* match *)
                        with_type TBool (EMatch (
                          (* y with *)
                          with_type t (EBound (n + 1)),
                          let binders_y = List.map (fun (f, (t, _)) ->
                            fresh_binder (KPrint.bsprintf "y_%s" f) t
                          ) fields in
                          [
                            (* \. yn ... y0 *)
                            List.rev binders_y,
                            (* A y0 ... yn -> *)
                            with_type t (PCons (cons, List.mapi (fun i (_, (t_f, _)) ->
                              with_type t_f (PBound i)) fields)),
                            (* ___eq___ xi yi *)
                            mk_conj_or_disj (List.mapi (fun i (_, (t, _)) ->
                              mk_rec_equality t (EBound i) (EBound (n + i))
                            ) fields);
                            (* _ -> false *)
                            [],
                            with_type t PWild,
                            fail_case
                      ]))) branches @ [
                        (* _ -> false *)
                        [],
                        with_type t PWild,
                        fail_case
                      ]))) in
                EQualified (Gen.register_def current_file eq_lid [ t ] instance_lid def)
          end

      | _ ->
          try
            (* Already monomorphized? *)
            EQualified (Hashtbl.find Gen.generated_lids (eq_lid, [ t ]))
          with Not_found ->
            (* External type without a definition. Comparison of function types? *)
            gen_poly ()

    (* New feature (somewhat unrelated to polymorphic equality
     * monomorphization): generate top-level specialized equalities in case a
     * higher-order occurrence of the equality operator occurs, at a scalar
     * type. *)

    method private eta_expand_op c t =
      let eq_lid = match c with
        | K.PEq -> [], "__eq"
        | K.PNeq -> [], "__neq"
      in
      try
        (* Already monomorphized? *)
        let existing_lid = Hashtbl.find Gen.generated_lids (eq_lid, [ t ]) in
        EQualified existing_lid
      with Not_found ->
        let eq_typ = TArrow (t, TArrow (t, TBool)) in
        let instance_lid = Gen.gen_lid eq_lid [ t ] in
        let x = fresh_binder "x" t in
        let y = fresh_binder "y" t in
        EQualified (Gen.register_def current_file eq_lid [ t ] instance_lid (fun _ ->
          DFunction (None, [ Common.Private ], 0, TBool, instance_lid, [ y; x ],
            with_type TBool (
              EApp (with_type eq_typ (EPolyComp (c, t)), [
                with_type t (EBound 0); with_type t (EBound 1) ])))))

    method! visit_EApp env e es =
      match e.node, es with
      | EPolyComp (op, t), [ x; y ] ->
          self#maybe_by_addr (self#generate_equality t op) (self#visit_expr env x) (self#visit_expr env y)
      | _ ->
          EApp (self#visit_expr env e, List.map (self#visit_expr env) es)

    method! visit_EPolyComp _ c t =
      (* We are NOT under an application, meaning this is an unapplied equality
         stemming from a higher-order usage of a monomorphic equality operator.
         We perform something similar to `generate_equality` above, namely, we
         register a top-level function that "fills in" for this equality
         function. *)
      self#eta_expand_op c t

  end in

  monomorphize#visit_files () files
