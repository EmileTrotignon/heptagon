(** Scoping. Introduces unique indexes for local names and replace global
    names by qualified names *)

open Location
open Parsetree
open Names
open Ident
open Format
open Printf
open Static

module Error =
struct
  type error =
    | Evar of string
    | Econst_var of string
    | Evariable_already_defined of string
    | Econst_variable_already_defined of string
    | Estatic_exp_expected

  let message loc kind =
    begin match kind with
      | Evar name ->
          eprintf "%aThe value identifier %s is unbound.\n"
            output_location loc 
	    name
      | Econst_var name ->
          eprintf "%aThe const identifier %s is unbound.\n"
            output_location loc 
	    name
      | Evariable_already_defined name ->
          eprintf "%aThe variable %s is already defined.\n"
            output_location loc 
	    name
      | Econst_variable_already_defined name ->
          eprintf "%aThe const variable %s is already defined.\n"
            output_location loc 
	    name
      | Estatic_exp_expected ->
          eprintf "%aA static expression was expected.\n"
            output_location loc 	  
    end;
    raise Misc.Error
end

module Rename =
struct
  include
  (Map.Make (struct type t = string let compare = String.compare end))
  let append env0 env =
    fold (fun key v env -> add key v env) env0 env

  let name loc env n =
    try
      find n env
    with
	Not_found -> Error.message loc (Error.Evar(n))    
end
	
(*Functions to build the renaming map*)
let add_var loc x env =
  if Rename.mem x env then
    Error.message loc (Error.Evariable_already_defined x)
  else (* create a new id for this var and add it to the env *)
    Rename.add x (ident_of_var x) env

let add_const_var loc x env =
  if NamesEnv.mem x env then
    Error.message loc (Error.Econst_variable_already_defined x)
  else (* create a new id for this var and add it to the env *)
    NamesEnv.add x (ident_of_var x) env

let rec build_pat loc env = function
  | Evarpat x -> add_var loc x env
  | Etuplepat l -> 
      List.fold_left (build_pat loc) env l
	
let build_vd_list env l =
  let build_vd env vd =
    add_var vd.v_loc vd.v_name env
  in
    List.fold_left build_vd env l

let build_cd_list env l =
  let build_cd env cd =
    add_const_var cd.c_loc cd.c_name env
  in
    List.fold_left build_cd env l

let build_id_list loc env l =
  let build_id env id =
    add_const_var loc id env
  in  
    List.fold_left build_id env l

(* Translate the AST into Heptagon. *)
let translate_inlining_policy = function
  | Ino -> Heptagon.Ino
  | Ione -> Heptagon.Ione
  | Irec -> Heptagon.Irec

let translate_const = function
  | Cint i -> Heptagon.Cint i
  | Cfloat f -> Heptagon.Cfloat f
  | Cconstr ln -> Heptagon.Cconstr ln

let op_from_app loc app =
  match app.a_op with
    | Eop (op,_) -> op_from_app_name op
    | _ -> Error.message loc Error.Estatic_exp_expected

let check_const_vars = ref true
let rec translate_size_exp const_env e =
  match e.e_desc with 
  | Evar n ->
      if !check_const_vars & not (NamesEnv.mem n const_env) then
	Error.message e.e_loc (Error.Econst_var n)
      else
	SVar n
  | Econst (Cint i) -> SConst i
  | Eapp(app, [e1;e2]) ->
      let op = op_from_app e.e_loc app in
	SOp(op, translate_size_exp const_env e1, translate_size_exp const_env e2)
  | _ -> Error.message e.e_loc Error.Estatic_exp_expected

let rec translate_type const_env = function
  | Tprod ty_list -> 
      Heptagon.Tprod(List.map (translate_type const_env) ty_list)
  | Tid ln -> Heptagon.Tbase (Heptagon.Tid ln)
  | Tarray (ty, e) -> 
      let ty = Heptagon.base_type (translate_type const_env ty) in
	Heptagon.Tbase (Heptagon.Tarray (ty, translate_size_exp const_env e))

and translate_exp const_env env e = 
  { Heptagon.e_desc = translate_desc e.e_loc const_env env e.e_desc;
    Heptagon.e_ty = Heptagon.Tprod [];
    Heptagon.e_linearity = Linearity.NotLinear;
    Heptagon.e_loc = e.e_loc }

and translate_app const_env env app =
  let op = match app.a_op with
    | Epre None -> Heptagon.Epre None
    | Epre (Some c) -> Heptagon.Epre (Some (translate_const c))
    | Efby -> Heptagon.Efby
    | Earrow -> Heptagon.Earrow
    | Eifthenelse -> Heptagon.Eifthenelse
    | Erepeat -> Heptagon.Erepeat
    | Eselect_slice -> Heptagon.Eselect_slice
    | Econcat -> Heptagon.Econcat
    | Ecopy -> Heptagon.Ecopy
    | Eselect_dyn -> Heptagon.Eselect_dyn 
    | Enode (ln, params) -> Heptagon.Enode (ln, List.map (translate_size_exp const_env) params)
    | Eevery (ln, params) -> Heptagon.Eevery (ln, List.map (translate_size_exp const_env) params)
    | Eop (ln, params) -> Heptagon.Eop (ln, List.map (translate_size_exp const_env) params)
    | Eselect e_list -> Heptagon.Eselect (List.map (translate_size_exp const_env) e_list)
    | Eupdate e_list -> Heptagon.Eupdate (List.map (translate_size_exp const_env) e_list)
    | Eiterator (it, ln, params) -> 
	Heptagon.Eiterator (it, ln, List.map (translate_size_exp const_env) params, None)
    | Efield_update f -> Heptagon.Efield_update f
    | Emake f -> Heptagon.Emake f
    | Eflatten f -> Heptagon.Eflatten f
  in
    { Heptagon.a_op = op;
      Heptagon.a_inlined = translate_inlining_policy app.a_inlined }
    
and translate_desc loc const_env env = function
  | Econst c -> Heptagon.Econst (translate_const c)
  | Evar x -> 
      if Rename.mem x env then  
	Heptagon.Evar (Rename.name loc env x)
      else if NamesEnv.mem x const_env then (* var not defined, maybe a const var*)
	Heptagon.Econstvar x
      else
	Error.message loc (Error.Evar x)  
  | Elast x ->  Heptagon.Elast (Rename.name loc env x)
  | Etuple e_list -> Heptagon.Etuple (List.map (translate_exp const_env env) e_list)
  | Eapp ({ a_op = Erepeat} as app, e_list) ->
      let e_list = List.map (translate_exp const_env env) e_list in
	(match e_list with
	   | [{ Heptagon.e_desc = Heptagon.Econst c }; e1 ] -> 
	       Heptagon.Econst (Heptagon.Cconst_array (Heptagon.size_exp_of_exp e1, c))
	   | _ -> Heptagon.Eapp (translate_app const_env env app, e_list)
	)
  | Eapp (app, e_list) ->
      let e_list = List.map (translate_exp const_env env) e_list in
	Heptagon.Eapp (translate_app const_env env app, e_list)
  | Efield (e, field) -> Heptagon.Efield (translate_exp const_env env e, field)
  | Estruct f_e_list ->
      let f_e_list = List.map (fun (f,e) -> f, translate_exp const_env env e) f_e_list in
	Heptagon.Estruct f_e_list
  | Earray e_list -> Heptagon.Earray (List.map (translate_exp const_env env) e_list)

and translate_pat loc env = function
  | Evarpat x -> Heptagon.Evarpat (Rename.name loc env x)
  | Etuplepat l -> Heptagon.Etuplepat (List.map (translate_pat loc env) l)

let rec translate_eq const_env env eq =
  { Heptagon.eq_desc = translate_eq_desc eq.eq_loc const_env env eq.eq_desc ;
    Heptagon.eq_statefull = false; 
    Heptagon.eq_loc = eq.eq_loc }

and translate_eq_desc loc const_env env = function
    | Eswitch(e, switch_handlers) ->
	Heptagon.Eswitch (translate_exp const_env env e,
			 List.map (translate_switch_handler loc const_env env) switch_handlers)
    | Eeq(p, e) ->
	Heptagon.Eeq (translate_pat loc env p, translate_exp const_env env e)
    | Epresent (present_handlers, b) ->
	Heptagon.Epresent (List.map (translate_present_handler const_env env) present_handlers,
			  translate_block const_env env b)
    | Eautomaton state_handlers ->
	Heptagon.Eautomaton (List.map (translate_state_handler const_env env) state_handlers)
    | Ereset (eq_list, e) ->
	Heptagon.Ereset (List.map (translate_eq const_env env) eq_list,
			translate_exp const_env env e)

and translate_block const_env env b =
  let env = build_vd_list env b.b_local in

  { Heptagon.b_local = translate_vd_list const_env env b.b_local;
    Heptagon.b_equs = List.map (translate_eq const_env env) b.b_equs;
    Heptagon.b_defnames = Env.empty ;  
    Heptagon.b_statefull = false; 
    Heptagon.b_loc = b.b_loc }

and translate_state_handler const_env env sh =
  { Heptagon.s_state = sh.s_state;
    Heptagon.s_block = translate_block const_env env sh.s_block;
    Heptagon.s_until = List.map (translate_escape const_env env) sh.s_until;
    Heptagon.s_unless = List.map (translate_escape const_env env) sh.s_unless; }

and translate_escape const_env env esc =
  { Heptagon.e_cond = translate_exp const_env env esc.e_cond;
    Heptagon.e_reset = esc.e_reset;
    Heptagon.e_next_state = esc.e_next_state }

and translate_present_handler const_env env ph =
  { Heptagon.p_cond = translate_exp const_env env ph.p_cond;
    Heptagon.p_block = translate_block const_env env ph.p_block }

and translate_switch_handler loc const_env env sh =
  { Heptagon.w_name = sh.w_name;
    Heptagon.w_block = translate_block const_env env sh.w_block }

and translate_var_dec const_env env vd = 
  { Heptagon.v_name = Rename.name vd.v_loc env vd.v_name;
    Heptagon.v_type = Heptagon.base_type (translate_type const_env vd.v_type);
    Heptagon.v_linearity = vd.v_linearity;
    Heptagon.v_last = translate_last env vd.v_last;
    Heptagon.v_loc = vd.v_loc } 

and translate_vd_list const_env env =
  List.map (translate_var_dec const_env env)

and translate_last env = function
  | Var -> Heptagon.Var
  | Last (None) -> Heptagon.Last None
  | Last (Some c) -> Heptagon.Last (Some (translate_const c))
    
let translate_contract const_env env ct =
  { Heptagon.c_assume = translate_exp const_env env ct.c_assume;
    Heptagon.c_enforce = translate_exp const_env env ct.c_enforce; 
    Heptagon.c_controllables = translate_vd_list const_env env ct.c_controllables; 
    Heptagon.c_local = translate_vd_list const_env env ct.c_local;
    Heptagon.c_eq = List.map (translate_eq const_env env) ct.c_eq }

let translate_node const_env env node =
  let const_env = build_id_list node.n_loc const_env node.n_params in
  let env = build_vd_list env (node.n_input @ node.n_output @ node.n_local) in
  { Heptagon.n_name = node.n_name;
    Heptagon.n_statefull = node.n_statefull;
    Heptagon.n_input = translate_vd_list const_env env node.n_input;
    Heptagon.n_output = translate_vd_list const_env env node.n_output;
    Heptagon.n_local = translate_vd_list const_env env node.n_local;
    Heptagon.n_contract = Misc.optional (translate_contract const_env env) node.n_contract;
    Heptagon.n_equs = List.map (translate_eq const_env env) node.n_equs;
    Heptagon.n_loc = node.n_loc; 
    Heptagon.n_states_graph = Interference_graph.mk_graph [] "";
    Heptagon.n_params = node.n_params;
    Heptagon.n_params_constraints = []; }

let translate_typedec const_env ty =
  let onetype = function
    | Type_abs -> Heptagon.Type_abs
    | Type_enum(tag_list) -> Heptagon.Type_enum(tag_list)
    | Type_struct(field_ty_list) ->
	let translate_field_type (f,ty) = 
	  f, Heptagon.base_type (translate_type const_env ty)
	in
	  Heptagon.Type_struct (List.map translate_field_type field_ty_list)
  in
    { Heptagon.t_name = ty.t_name; 
      Heptagon.t_desc = onetype ty.t_desc;
      Heptagon.t_loc = ty.t_loc }

let translate_const_dec const_env cd =
  { Heptagon.c_name = cd.c_name;
    Heptagon.c_type = Heptagon.base_type (translate_type const_env cd.c_type);
    Heptagon.c_value = translate_size_exp const_env cd.c_value;
    Heptagon.c_loc = cd.c_loc; }

let translate_program p =
  let const_env = build_cd_list NamesEnv.empty p.p_consts in
  { Heptagon.p_pragmas = p.p_pragmas;
    Heptagon.p_opened = p.p_opened;
    Heptagon.p_types = List.map (translate_typedec const_env) p.p_types;
    Heptagon.p_nodes = List.map (translate_node const_env Rename.empty) p.p_nodes;
    Heptagon.p_consts = List.map (translate_const_dec const_env) p.p_consts; }

let translate_signature const_env s =
  let translate_field_type (f,(ty,lin)) = 
    f, Heptagon.base_type (translate_type const_env ty), lin
  in
    
  let const_env = build_id_list no_location const_env s.sig_params in
  { Heptagon.sig_name = s.sig_name;
    Heptagon.sig_inputs = List.map translate_field_type s.sig_inputs;
    Heptagon.sig_outputs = List.map translate_field_type s.sig_outputs;
    Heptagon.sig_node = s.sig_node;
    Heptagon.sig_safe = s.sig_safe;
    Heptagon.sig_params = s.sig_params; }

let translate_interface_desc const_env = function 
  | Iopen n -> Heptagon.Iopen n
  | Itypedef tydec -> Heptagon.Itypedef (translate_typedec const_env tydec)
  | Isignature s -> Heptagon.Isignature (translate_signature const_env s) 

let translate_interface_decl const_env idecl = 
  { Heptagon.interf_desc = translate_interface_desc const_env idecl.interf_desc; 
    Heptagon.interf_loc = idecl.interf_loc }

let translate_interface = 
  List.map (translate_interface_decl NamesEnv.empty)

