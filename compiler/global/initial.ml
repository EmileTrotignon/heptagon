(**************************************************************************)
(*                                                                        *)
(*  Heptagon                                                              *)
(*                                                                        *)
(*  Author : Marc Pouzet                                                  *)
(*  Organization : Demons, LRI, University of Paris-Sud, Orsay            *)
(*                                                                        *)
(**************************************************************************)
(* initialization of the typing environment *)

open Names

let tglobal = []
let cglobal = []

let pbool = Modname({ qual = "Pervasives"; id = "bool" })
let ptrue = Modname({ qual = "Pervasives"; id = "true" })
let pfalse = Modname({ qual = "Pervasives"; id = "false" })
let por = Modname({ qual = "Pervasives"; id = "or" })
let pint = Modname({ qual = "Pervasives"; id = "int" })
let pfloat = Modname({ qual = "Pervasives"; id = "float" })

(* build the initial environment *)
let initialize () =
  List.iter (fun (f, ty) -> Modules.add_type f ty) tglobal;
  List.iter (fun (f, ty) -> Modules.add_constr f ty) cglobal