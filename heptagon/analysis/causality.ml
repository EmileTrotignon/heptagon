(**************************************************************************)
(*                                                                        *)
(*  Heptagon                                                              *)
(*                                                                        *)
(*  Author : Marc Pouzet                                                  *)
(*  Organization : Demons, LRI, University of Paris-Sud, Orsay            *)
(*                                                                        *)
(**************************************************************************)

(* causality check *)

(* $Id: causality.ml 615 2009-11-20 17:43:14Z pouzet $ *)

open Misc
open Names 
open Ident
open Heptagon
open Location
open Linearity
open Graph
open Causal

let cempty = Cempty
let is_empty c = (c = cempty)

let cand c1 c2 =
  match c1, c2 with
  | Cempty, _ -> c2 | _, Cempty -> c1
  | c1, c2 -> Cand(c1, c2)
let rec candlist l =
  match l with
  | [] -> Cempty
  | c1 :: l -> cand c1 (candlist l)

let ctuplelist l =
  Ctuple l

let cor c1 c2 =
  match c1, c2 with
  | Cempty, Cempty -> Cempty
  | _ -> Cor(c1, c2)
let rec corlist l =
  match l with
  | [] -> Cempty
  | [c1] -> c1
  | c1 :: l -> cor c1 (corlist l)

let cseq c1 c2 =
  match c1, c2 with
  | Cempty, _ -> c2
  | _, Cempty -> c1
  | c1, c2 -> Cseq(c1, c2)
let rec cseqlist l =
  match l with
  | [] -> Cempty
  | c1 :: l -> cseq c1 (cseqlist l)

let read x = Cread(x)
let linread x = Clinread(x)
let lastread x = Clastread(x)
let cwrite x = Cwrite(x)

(* cutting dependences with a delay operator *)
let rec pre = function
  | Cor(c1, c2) -> Cor(pre c1, pre c2)
  | Cand(c1, c2) -> Cand(pre c1, pre c2)
  | Ctuple l -> Ctuple (List.map pre l)
  | Cseq(c1, c2) -> Cseq(pre c1, pre c2)
  | Cread(x) | Clinread (x) -> Cempty
  | (Cwrite _ | Clastread _ | Cempty) as c -> c

(* projection and restriction *)
let clear env c =
  let rec clearec c =
    match c with
    | Cor(c1, c2) ->
        let c1 = clearec c1 in
        let c2 = clearec c2 in
        cor c1 c2
    | Cand(c1, c2) ->
        let c1 = clearec c1 in
        let c2 = clearec c2 in
        cand c1 c2
    | Cseq(c1, c2) ->
        let c1 = clearec c1 in
        let c2 = clearec c2 in
        cseq c1 c2
    | Ctuple l -> Ctuple (List.map clearec l)
    | Cwrite(id) | Cread(id) | Clinread(id) | Clastread(id) ->
        if IdentSet.mem id env then Cempty else c
    | Cempty -> c in
  clearec c

let build dec = 
  List.fold_left (fun acc { v_name = n } -> IdentSet.add n acc) IdentSet.empty dec
 
(** Main typing function *)
let rec typing e =
  match e.e_desc with
    | Econst(c) -> cempty
    | Econstvar(x) -> cempty
    | Evar(x) -> 
	(match e.e_linearity with
	   | At _ -> linread x
	   | _ -> read x
	)
    | Elast(x) -> lastread x
    | Etuple(e_list) ->
	candlist (List.map typing e_list)
    | Eapp({a_op = op}, e_list) -> apply op e_list
    | Efield(e1, _) -> typing e1
    | Estruct(l) ->
	let l = List.map (fun (_, e) -> typing e) l in
	candlist l
    | Earray(e_list) ->
	candlist (List.map typing e_list)
    | Ereset_mem _ -> assert false

(** Typing an application *)
and apply op e_list =
  match op, e_list with
    | Epre(_), [e] -> pre (typing e)
    | Efby, [e1;e2] ->
	let t1 = typing e1 in
	let t2 = pre (typing e2) in
	candlist [t1; t2]
    | Earrow, [e1;e2] ->
	let t1 = typing e1 in
	let t2 = typing e2 in
	candlist [t1; t2]
    | Eifthenelse, [e1; e2; e3] ->
	let t1 = typing e1 in
	let i2 = typing e2 in
	let i3 = typing e3 in
	cseq t1 (cor i2 i3)
    | (Enode _ | Eevery _ | Eop _ | Eiterator (_, _, _, _)
      | Econcat | Eselect_slice | Emake _ | Eflatten _
      | Eselect_dyn | Eselect _ | Erepeat | Ecopy), e_list ->
	ctuplelist (List.map typing e_list)
    | Eupdate _, [e1;e2] | Efield_update _, [e1;e2] ->
	let t1 = typing e1 in
	let t2 = typing e2 in
	cseq t2 t1
	
let rec typing_pat = function
  | Evarpat(x) -> cwrite(x)
  | Etuplepat(pat_list) ->
      candlist (List.map typing_pat pat_list)

(** Typing equations *)
let rec typing_eqs eq_list = candlist (List.map typing_eq eq_list)

and typing_eq eq =
  match eq.eq_desc with
    | Eautomaton(handlers) -> typing_automaton handlers
    | Eswitch(e, handlers) ->
	cseq (typing e) (typing_switch handlers)
    | Epresent(handlers, b) -> 
	typing_present handlers b
    | Ereset(eq_list, e) ->
	cseq (typing e) (typing_eqs eq_list)
    | Eeq(pat, e) ->
	cseq (typing e) (typing_pat pat)

and typing_switch handlers =
  let handler { w_block = b } = typing_block b in
  corlist (List.map handler handlers)

and typing_present handlers b =
  let handler { p_cond = e; p_block = b } =
    cseq (typing e) (typing_block b) in
  corlist ((typing_block b) :: (List.map handler handlers))

and typing_automaton state_handlers =
  (* typing the body of the automaton *)
  let handler 
      { s_state = _; s_block = b; s_until = suntil; s_unless = sunless } =
    let escape { e_cond = e } = typing e in

    (* typing the body *)
    let tb = typing_block b in
    let t1 = candlist (List.map escape suntil) in
    let t2 = candlist (List.map escape sunless) in

    cseq t2 (cseq tb t1) in
  corlist (List.map handler state_handlers)

and typing_block { b_local = dec; b_equs = eq_list; b_loc = loc } =
  let teq = typing_eqs eq_list in
  Causal.check loc teq;
  clear (build dec) teq

let typing_contract loc contract =
  match contract with
    | None -> cempty
    | Some { c_local = l_list; c_eq = eq_list; c_assume = e_a; 
	     c_enforce = e_g; c_controllables = c_list } ->
	let teq = typing_eqs eq_list in
	let t_contract = cseq (typing e_a) (cseq teq (typing e_g)) in
	Causal.check loc t_contract;
	let t_contract = clear (build l_list) t_contract in
	t_contract

let typing_node { n_name = f; n_input = i_list; n_output = o_list;
		  n_contract = contract;
		  n_local = l_list; n_equs = eq_list; n_loc = loc } =
  let _ = typing_contract loc contract in
  let teq = typing_eqs eq_list in
  Causal.check loc teq

let program ({ p_nodes = p_node_list } as p) =
  List.iter typing_node p_node_list;
  p

