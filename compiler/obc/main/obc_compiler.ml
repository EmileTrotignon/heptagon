(**************************************************************************)
(*                                                                        *)
(*  Heptagon                                                              *)
(*                                                                        *)
(*  Author : Marc Pouzet                                                  *)
(*  Organization : Demons, LRI, University of Paris-Sud, Orsay            *)
(*                                                                        *)
(**************************************************************************)
open Misc
open Location
open Compiler_utils
open Compiler_options

let pp p = if !verbose then Obc_printer.print stdout p

let compile_program p =
  (*Control optimization*)
  let p = pass "Control optimization" true Control.program p pp in

  (* Memory allocation application *)
  let p = pass "Application of Memory Allocation" !do_mem_alloc Memalloc_apply.program p pp in

  p
