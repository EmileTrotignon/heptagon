(**************************************************************************)
(*                                                                        *)
(*  Heptagon                                                              *)
(*                                                                        *)
(*  Author : Marc Pouzet                                                  *)
(*  Organization : Demons, LRI, University of Paris-Sud, Orsay            *)
(*                                                                        *)
(**************************************************************************)
(* $Id$ *)

open Misc
open Names
open Ident
open Global
open Minils

let ctrue = Name("true")
and cfalse = Name("false")

let equation (d_list, eq_list) ({ e_ty = te; e_linearity = l; e_ck = ck } as e) =
  let n = Ident.fresh "_v" in
  let d_list = { v_name = n; v_copy_of = None;
		 v_type = type te; v_linearity = l; v_clock = ck } :: d_list
  and eq_list = { eq_lhs = Evarpat(n); eq_rhs = e } :: eq_list in
  (d_list, eq_list), n

let intro context e =
  match e.e_desc with
      Evar(n) -> context, n
    | _ -> equation context e

(* distribution: [(e1,...,ek) when C(n) = (e1 when C(n),...,ek when C(n))] *)
let rec whenc context e c n =
  let when_on_c c n e =
    { e with e_desc = Ewhen(e, c, n); e_ck = Con(e.e_ck, c, n) } in

  match e.e_desc with
    | Etuple(e_list) ->
        let context, e_list =
          List.fold_right
            (fun e (context, e_list) -> let context, e = whenc context e c n in
             (context, e :: e_list))
            e_list (context, []) in
        context, { e with e_desc = Etuple(e_list); e_ck = Con(e.e_ck, c, n) }
    (* | Emerge _ -> let context, x = equation context e in
      context, when_on_c c n { e with e_desc = Evar(x) } *)
    | _ -> context, when_on_c c n e

(* transforms [merge x (c1, (e11,...,e1n));...;(ck, (ek1,...,ekn))] into *)
(* [merge x (c1, e11)...(ck, ek1),..., merge x (c1, e1n)...(ck, ekn)]    *)
let rec merge e x ci_a_list =
  let rec split ci_tas_list =
    match ci_tas_list with
      | [] | (_, _, []) :: _ -> [], []
      | (ci, b, a :: tas) :: ci_tas_list ->
          let ci_ta_list, ci_tas_list = split ci_tas_list in
          (ci, a) :: ci_ta_list, (ci, b, tas) :: ci_tas_list in
  let rec distribute ci_tas_list =
    match ci_tas_list with
      | [] | (_, _, []) :: _ -> []
      | (ci, b, (eo :: _)) :: _ ->
          let ci_ta_list, ci_tas_list = split ci_tas_list in
          let ci_tas_list = distribute ci_tas_list in
          (if b then
             { eo with e_desc = Emerge(x, ci_ta_list);
                 e_ck = e.e_ck; e_loc = e.e_loc }
           else
             merge e x ci_ta_list)
          :: ci_tas_list in
  let rec erasetuple ci_a_list =
    match ci_a_list with
      | [] -> []
      | (ci, { e_desc = Etuple(l) }) :: ci_a_list ->
          (ci, false, l) :: erasetuple ci_a_list
      | (ci, e) :: ci_a_list ->
          (ci, true, [e]) :: erasetuple ci_a_list in
  let ci_tas_list = erasetuple ci_a_list in
  let ci_tas_list = distribute ci_tas_list in
  match ci_tas_list with
    | [e] -> e
    | l -> { e with e_desc = Etuple(l) }

let ifthenelse context e1 e2 e3 =
  let context, n = intro context e1 in
  let context, e2 = whenc context e2 ctrue n in
  let context, e3 = whenc context e3 cfalse n in
  context, merge e1 n [ctrue, e2; cfalse, e3]

let const e c =
  let rec const = function
    | Cbase | Cvar { contents = Cindex _ } -> c
    | Con(ck_on, tag, x) ->
        Ewhen({ e with e_desc = const ck_on; e_ck = ck_on }, tag, x)
    | Cvar { contents = Clink ck } -> const ck in
  const e.e_ck

(* normal form for expressions and equations:                              *)
(* - e ::= op(e,...,e) | x | C | e when C(x)                               *)
(* - act ::= e | merge x (C1 -> act) ... (Cn -> act) | (act,...,act)       *)
(* - eq ::= [x = v fby e] | [pat = act ] | [pat = f(e1,...,en) every n     *)
(* - A-normal form: (e1,...,en) when c(x) = (e1 when c(x),...,en when c(x) *)
type kind = VRefCond | VRef | Exp | Act | Any

let function_args_kind = if !no_mem_alloc then Exp else VRefCond
let merge_kind = if !no_mem_alloc then Act else VRef

let rec constant e = match e.e_desc with
  | Econst _ | Econstvar _ -> true
  | Ewhen(e, _, _) -> constant e
  | Evar _ -> true
  | _ -> false

let add context expected_kind ({ e_desc = de; e_linearity = l } as e) =
  let up = match de, expected_kind with
    | (Evar _ | Efield _ ) , VRefCond -> false
    | Efby _, VRefCond -> true
    | _ , VRefCond -> not (Linearity.is_not_linear l)
    | (Evar _ | Efield _ ) , VRef -> false
    | _ , VRef -> true
    | ( Emerge _ | Etuple _
      | Eapp _   | Eevery _ | Efby _ | Eselect_dyn _
      | Eupdate _ | Econcat _ | Erepeat _ | Eiterator _
      | Eselect_slice _ ), Exp -> true
    | ( Eapp _ | Eevery _ | Efby _ ), Act -> true
    | _ -> false in
  if up then
    let context, n = equation context e in
    context, { e with e_desc = Evar(n) }
  else context, e

let rec translate kind context e =
  let context, e = match e.e_desc with
    | Emerge(n, tag_e_list) ->
        let context, ta_list =
          List.fold_right
            (fun (tag, e) (context, ta_list) ->
               let context, act = translate merge_kind context e in
               context, ((tag, act) :: ta_list))
            tag_e_list (context, []) in
        context, merge e n ta_list
    | Eifthenelse(e1, e2, e3) ->
        let context, e1 = translate Any context e1 in
        let context, e2 = translate Act context e2 in
        let context, e3 = translate Act context e3 in
        ifthenelse context e1 e2 e3
    | Etuple(e_list) ->
        let context, e_list = translate_list kind context e_list in
        context, { e with e_desc = Etuple(e_list) }
    | Ewhen(e1, c, n) ->
        let context, e1 = translate kind context e1 in
        whenc context e1 c n
    | Eop(op, params, e_list) ->
        let context, e_list = translate_list function_args_kind context e_list in
        context, { e with e_desc = Eop(op, params, e_list) }
    | Eapp(app, params, e_list) ->
        let context, e_list = translate_list function_args_kind context e_list in
        context, { e with e_desc = Eapp(app, params, e_list) }
    | Eevery(app, params, e_list, n) ->
        let context, e_list = translate_list function_args_kind context e_list in
        context, { e with e_desc = Eevery(app, params, e_list, n) }
    | Efby(v, e1) ->
        let context, e1 = translate Exp context e1 in
        let context, e1' =
	  if constant e1 then context, e1 
	  else let context, n = equation context e1 in
	       context, { e1 with e_desc = Evar(n) } in
        context, { e with e_desc = Efby(v, e1') }
    | Ereset_mem (_, _, _) -> context, e
    | Evar _ -> context, e
    | Econst(c) -> context, { e with e_desc = const e (Econst c) }
    | Econstvar x -> context, { e with e_desc = const e (Econstvar x) }
    | Efield(e', field) ->
        let context, e' = translate Exp context e' in
        context, { e with e_desc = Efield(e', field) }
    | Estruct(l) ->
        let context, l =
          List.fold_right
            (fun (field, e) (context, field_desc_list) ->
               let context, e = translate Exp context e in
               context, ((field, e) :: field_desc_list))
            l (context, []) in
        context, { e with e_desc = Estruct(l) }
(*Array operators*)
    | Earray(e_list) -> 
	let context, e_list = translate_list kind context e_list in
	  context, { e with e_desc = Earray(e_list) }
    | Erepeat (n,e') ->
	let context, e' = translate VRef context e' in
          context, { e with e_desc = Erepeat(n, e') }
    | Eselect (idx,e') -> 
	let context, e' = translate VRef context e' in
          context, { e with e_desc = Eselect(idx, e') }
    | Eselect_dyn (idx, bounds, e1, e2) ->
	let context, e1 = translate VRef context e1 in
	let context, idx = translate_list Exp context idx in
	let context, e2 = translate Exp context e2 in  
          context, { e with e_desc = Eselect_dyn(idx, bounds, e1, e2) }
    | Eupdate (idx, e1, e2)  ->
	let context, e1 = translate VRef context e1 in
	let context, e2 = translate Exp context e2 in  
          context, { e with e_desc = Eupdate(idx, e1, e2) }
    | Eselect_slice (idx1, idx2, e') ->
	let context, e' = translate VRef context e' in
          context, { e with e_desc = Eselect_slice(idx1, idx2, e') }
    | Econcat (e1, e2) -> 
	let context, e1 = translate VRef context e1 in
	let context, e2 = translate VRef context e2 in  
          context, { e with e_desc = Econcat(e1, e2) }	
    | Eiterator (it, f, params, n, e_list, reset) ->
	let context, e_list = translate_list function_args_kind context e_list in
	  context, { e with e_desc = Eiterator(it, f, params, n, e_list, reset) }
    | Efield_update (f, e1, e2) ->
	let context, e1 = translate VRef context e1 in
	let context, e2 = translate Exp context e2 in  
          context, { e with e_desc = Efield_update(f, e1, e2) }	
  in add context kind e

and translate_list kind context e_list =
  match e_list with
      [] -> context, []
    | e :: e_list ->
        let context, e = translate kind context e in
        let context, e_list = translate_list kind context e_list in
        context, e :: e_list

let rec translate_eq context pat e =
  (* applies distribution rules *)
  (* [x = v fby e] should verifies that x is local *)
  (* [(p1,...,pn) = (e1,...,en)] into [p1 = e1;...;pn = en] *)
  let rec distribute ((d_list, eq_list) as context) pat e =
    match pat, e.e_desc with
      | Evarpat(x), Efby _ when not (vd_mem x d_list) ->
          let (d_list, eq_list), n = equation context e in
          d_list,
          { eq_lhs = pat; eq_rhs = { e with e_desc = Evar(n) } } :: eq_list
      | Etuplepat(pat_list), Etuple(e_list) ->
          List.fold_left2 distribute context pat_list e_list
      | _ -> d_list, { eq_lhs = pat; eq_rhs = e } :: eq_list in

  let context, e = translate Any context e in
  distribute context pat e

let translate_eq_list d_list eq_list =
  List.fold_left
    (fun context { eq_lhs = pat; eq_rhs = e } -> translate_eq context pat e)
    (d_list, []) eq_list

let translate_contract ({ c_eq = eq_list; c_local = d_list } as c) =
  let d_list,eq_list = translate_eq_list d_list eq_list in
  { c with
      c_local = d_list;
      c_eq = eq_list }

let translate_node ({ n_contract = contract;
                      n_local = d_list; n_equs = eq_list } as node) =
  let contract = optional translate_contract contract in
  let d_list, eq_list = translate_eq_list d_list eq_list in
  { node with n_contract = contract; n_local = d_list; n_equs = eq_list }

let program ({ p_nodes = p_node_list } as p) =
  { p with p_nodes = List.map translate_node p_node_list }
