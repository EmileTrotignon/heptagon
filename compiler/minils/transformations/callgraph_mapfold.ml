open Names
open Types
open Misc
open Location
open Signature
open Modules
open Static
open Global_mapfold
open Mls_mapfold
open Minils

module Error =
struct
  type error =
    | Enode_unbound of longname
    | Evar_unbound of name

  let message loc kind =
    begin match kind with
      | Enode_unbound ln ->
          Format.eprintf "%aUnknown node '%s'@."
            print_location loc
            (fullname ln)
      | Evar_unbound n ->
          Format.eprintf "%aUnbound static var '%s'\n"
            print_location loc
            n
    end;
    raise Misc.Error
end

module Param_instances :
sig
  type key = private static_exp (** Fully instantiated param *)
  type env = key NamesEnv.t
  val instantiate: env -> static_exp list -> key list
  val get_node_instances : LongNameEnv.key -> key list list
  val add_node_instance : LongNameEnv.key -> key list -> unit
  val build : env -> param list -> key list -> env
  module Instantiate :
  sig
    val program : program -> program
  end
end =
struct
  type key = static_exp
  type env = key NamesEnv.t

  (** An instance is a list of instantiated params *)
  type instance = key list
  (** two instances are equal if the desc of keys are equal *)
  let compare_instances =
    let compare se1 se2 = compare se1.se_desc se2.se_desc in
    Misc.make_list_compare compare

  module S = (** Instances set *)
    Set.Make(
      struct
        type t = instance
        let compare = compare_instances
      end)

  module M = (** Map instance to its instantiated node *)
    Map.Make(
      struct
        type t = longname * instance
        let compare (l1,i1) (l2,i2) =
          let cl = compare l1 l2 in
          if cl = 0 then compare_instances i1 i2 else cl
      end)

  (** Maps a couple (node name, params) to the name of the instantiated node *)
  let nodes_names = ref M.empty

  (** Maps a node to its list of instances *)
  let nodes_instances = ref LongNameEnv.empty

  (** create a params instance *)
  let instantiate m se = List.map (simplify m) se

  (** @return the name of the node corresponding to the instance of
      [ln] with the static parameters [params]. *)
  let node_for_params_call ln params = match params with
    | [] -> ln
    | _ -> let ln = M.find (ln,params) !nodes_names in ln

  (** Generates a fresh name for the the instance of
      [ln] with the static parameters [params] and stores it. *)
  let generate_new_name ln params = match params with
    | [] -> nodes_names := M.add (ln, params) ln !nodes_names
    | _ -> (match ln with
        | Modname { qual = q; id = id } ->
            let new_ln = Modname { qual = q;
                  (* TODO ??? c'est quoi ce nom ??? *)
                  (* l'utilite de fresh n'est vrai que si toute les fonctions
                     sont touchees.. ce qui n'est pas vrai cf main_nodes *)
                  (* TODO mettre les valeurs des params dans le nom *)
                                   id = id^(Idents.name (Idents.fresh "")) } in
            nodes_names := M.add (ln, params) new_ln !nodes_names
        | _ -> assert false)

  (** Adds an instance of a node. *)
  let add_node_instance ln params =
    (* get the already defined instances *)
    let instances = try LongNameEnv.find ln !nodes_instances
                    with Not_found -> S.empty in
    if S.mem params instances then () (* nothing to do *)
    else ( (* it's a new instance *)
      let instances = S.add params instances in
      nodes_instances := LongNameEnv.add ln instances !nodes_instances;
      generate_new_name ln params )

  (** @return the list of instances of a node. *)
  let get_node_instances ln =
   let instances_set =
      try LongNameEnv.find ln !nodes_instances
      with Not_found -> S.empty in
   S.elements instances_set


  (** Build an environment by instantiating the passed params *)
  let build env params_names params_values =
    List.fold_left2 (fun m { p_name = n } v -> NamesEnv.add n v m)
      env params_names (instantiate env params_values)


  (** This module creates an instance of a node with a given
      list of static parameters. *)
  module Instantiate =
  struct
    (** Replaces static parameters with their value in the instance. *)
    let static_exp funs m se =
      let se, _ = Global_mapfold.static_exp funs m se in
      let se = match se.se_desc with
        | Svar ln ->
            (match ln with
               | Name n ->
                   (try NamesEnv.find n m
                    with Not_found -> (* It should then be in the global env *)
                    (* TODO should we check it's in the global env ?
                       I guess it should not be necessary cf typing.
                       Error.message se.se_loc (Error.Evar_unbound n)) *)
                    se)
               | Modname _ -> se)
        | _ -> se in
      se, m

    (** Replaces nodes call with the call to the correct instance. *)
    let edesc funs m ed =
      let ed, _ = Mls_mapfold.edesc funs m ed in
      let ed = match ed with
        | Eapp ({ a_op = Efun ln; a_params = params } as app, e_list, r) ->
            let op = Efun (node_for_params_call ln (instantiate m params)) in
            Eapp ({ app with a_op = op; a_params = [] }, e_list, r)
        | Eapp ({ a_op = Enode ln; a_params = params } as app, e_list, r) ->
            let op = Enode (node_for_params_call ln (instantiate m params)) in
            Eapp ({ app with a_op = op; a_params = [] }, e_list, r)
        | Eiterator(it, ({ a_op = Efun ln; a_params = params } as app),
                      n, e_list, r) ->
            let op = Efun (node_for_params_call ln (instantiate m params)) in
            Eiterator(it, {app with a_op = op; a_params = [] }, n, e_list, r)
        | Eiterator(it, ({ a_op = Enode ln; a_params = params } as app),
                     n, e_list, r) ->
            let op = Enode (node_for_params_call ln (instantiate m params)) in
            Eiterator(it,{app with a_op = op; a_params = [] }, n, e_list, r)
        | _ -> ed
      in ed, m

    let node_dec_instance modname n params =
      let global_funs =
        { Global_mapfold.defaults with static_exp = static_exp } in
      let funs =
        { Mls_mapfold.defaults with edesc = edesc;
                                    global_funs = global_funs } in
      let m = build NamesEnv.empty n.n_params params in
      let n, _ = Mls_mapfold.node_dec_it funs m n in

      (* Add to the global environment the signature of the new instance *)
      let ln = Modname { qual = modname; id = n.n_name } in
      let { info = node_sig } = find_value ln in
      let node_sig, _ = Global_mapfold.node_it global_funs m node_sig in
      let node_sig = { node_sig with node_params = [];
                                     node_params_constraints = [] } in
      (* Find the name that was associated to this instance *)
      let ln = node_for_params_call ln params in
      Modules.add_value_by_longname ln node_sig;
      { n with n_name = shortname ln; n_params = []; n_params_constraints = [];}

    let node_dec modname n =
      let ln = Modname { qual = modname; id = n.n_name } in
      List.map (node_dec_instance modname n) (get_node_instances ln)

    let program p =
      { p
        with p_nodes = List.flatten (List.map (node_dec p.p_modname) p.p_nodes)}
  end

end

open Param_instances

type info =
  { mutable opened : program NamesEnv.t;
    mutable called_nodes : ((longname * static_exp list) list) LongNameEnv.t; }

let info =
  { (** opened programs*)
    opened = NamesEnv.empty;
    (** Maps a node to the list of (node name, params) it calls *)
    called_nodes = LongNameEnv.empty }

(** Loads the modname.epo file. *)
let load_object_file modname =
  Modules.open_module modname;
  let name = String.uncapitalize modname in
    try
      let filename = Modules.findfile (name ^ ".epo") in
      let ic = open_in_bin filename in
        try
          let p:program = input_value ic in
            if p.p_format_version <> minils_format_version then (
              Format.eprintf "The file %s was compiled with \
                       an older version of the compiler.\n \
                       Please recompile %s.ept first.\n" filename name;
              raise Error
            );
            close_in ic;
            info.opened <- NamesEnv.add p.p_modname p info.opened
        with
          | End_of_file | Failure _ ->
              close_in ic;
              Format.eprintf "Corrupted object file %s.\n\
                        Please recompile %s.ept first.\n" filename name;
              raise Error
    with
      | Modules.Cannot_find_file(filename) ->
          Format.eprintf "Cannot find the object file '%s'.\n"
            filename;
          raise Error

(** @return the node with name [ln], loading the corresponding
    object file if necessary. *)
let node_by_longname ln =
  match ln with
    | Modname { qual = q; id = id } ->
        if not (NamesEnv.mem q info.opened) then
          load_object_file q;
        (try
           let p = NamesEnv.find q info.opened in
             List.find (fun n -> n.n_name = id) p.p_nodes
         with
             Not_found -> Error.message no_location (Error.Enode_unbound ln))
    | _ -> assert false

(** @return the list of nodes called by the node named [ln], with the
    corresponding params (static parameters appear as free variables). *)
let collect_node_calls ln =
  let add_called_node ln params acc =
    match params with
      | [] -> acc
      | _ ->
          (match ln with
            | Modname { qual = "Pervasives" } -> acc
            | _ -> (ln, params)::acc)
  in
  let edesc funs acc ed = match ed with
    | Eapp ({ a_op = (Enode ln | Efun ln); a_params = params }, _, _) ->
        ed, add_called_node ln params acc
    | Eiterator(_, { a_op = (Enode ln | Efun ln); a_params = params },
                _, _, _) ->
        ed, add_called_node ln params acc
    | _ -> raise Misc.Fallback
  in
  let funs = { Mls_mapfold.defaults with edesc = edesc } in
  let n = node_by_longname ln in
  let _, acc = Mls_mapfold.node_dec funs [] n in
    acc

(** @return the list of nodes called by the node named [ln]. This list is
    computed lazily the first time it is needed. *)
let called_nodes ln =
  if not (LongNameEnv.mem ln info.called_nodes) then (
    let called = collect_node_calls ln in
      info.called_nodes <- LongNameEnv.add ln called info.called_nodes;
      called
  ) else
    LongNameEnv.find ln info.called_nodes

(*
(** Checks that a static expression does not contain any static parameter. *)
let check_no_static_var se =
  let static_exp_desc funs acc sed = match sed with
    | Svar (Name n) -> Error.message se.se_loc (Error.Evar_unbound n)
    | _ -> raise Misc.Fallback
  in
  let funs = { Global_mapfold.defaults with
                 static_exp_desc = static_exp_desc } in
  ignore (Global_mapfold.static_exp_it funs false se)
*)

(** Generates the list of instances of nodes needed to call
    [ln] with static parameters [params]. *)
let rec call_node (ln, params) =
  (* First, add the instance for this node *)
  let n = node_by_longname ln in
  let m = build NamesEnv.empty n.n_params params in
(*  List.iter check_no_static_var params; *)
  add_node_instance ln params;

  (* Recursively generate instances for called nodes. *)
  let call_list = called_nodes ln in
  let call_list =
    List.map (fun (ln, p) -> ln, instantiate m p) call_list in
  List.iter call_node call_list

let program p =
  (* Find the nodes without static parameters *)
  let main_nodes = List.filter (fun n -> is_empty n.n_params) p.p_nodes in
  let main_nodes = List.map (fun n -> (longname n.n_name, [])) main_nodes in
    info.opened <- NamesEnv.add p.p_modname p NamesEnv.empty;
    (* Creates the list of instances starting from these nodes *)
    List.iter call_node main_nodes;
    let p_list = NamesEnv.fold (fun _ p l -> p::l) info.opened [] in
      (* Generate all the needed instances *)
      List.map Param_instances.Instantiate.program p_list
