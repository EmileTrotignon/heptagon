(**************************************************************************)
(*                                                                        *)
(*  Heptagon                                                              *)
(*                                                                        *)
(*  Author : Marc Pouzet                                                  *)
(*  Organization : Demons, LRI, University of Paris-Sud, Orsay            *)
(*                                                                        *)
(**************************************************************************)


open Misc
open Modules
open Location
open Compiler_utils
open Hept_compiler



let compile_impl modname filename =
  (* input and output files *)
  let source_name = filename ^ ".ept" in
  let filename = String.uncapitalize filename
  and obj_interf_name = filename ^ ".epci"
  and mls_name = filename ^ ".mls" in

  let ic, lexbuf = lexbuf_from_file source_name
  and itc = open_out_bin obj_interf_name
  and mlsc = open_out mls_name in

  let close_all_files () =
    close_in ic;
    close_out itc;
    close_out mlsc in

  try
    init_compiler modname;
    add_include (Filename.dirname filename);

    (* Parsing of the file *)
    let p = do_silent_pass "Parsing" (parse_implementation modname) lexbuf in

    (* Convert the parse tree to Heptagon AST *)
    let p = do_pass "Scoping" Hept_scoping.translate_program p pp in

    (* Process the Heptagon AST *)
    let p = compile_impl pp p in
    Modules.write_current_module itc;

    (* Set pretty printer to the Minils one *)
    let pp = Mls_compiler.pp in

    (* Compile Heptagon to MiniLS *)
    let p = do_pass "Translation into MiniLs" Hept2mls.program p pp in
    Mls_printer.print mlsc p;

    (* Process the MiniLS AST *)
    let p = Mls_compiler.compile pp p in

    (* Generate the sequential code *)
    Mls2seq.program p;

    close_all_files ()

  with x -> close_all_files (); raise x


let main () =
  try
    Arg.parse
      [
        "-v",Arg.Set verbose, doc_verbose;
        "-version", Arg.Unit show_version, doc_version;
        "-i", Arg.Set print_types, doc_print_types;
        "-I", Arg.String add_include, doc_include;
        "-where", Arg.Unit locate_stdlib, doc_locate_stdlib;
        "-stdlib", Arg.String set_stdlib, doc_stdlib;
        "-c", Arg.Set create_object_file, doc_object_file;
        "-s", Arg.String set_simulation_node, doc_sim;
        "-inline", Arg.String add_inlined_node, doc_inline;
        "-flatten", Arg.Set flatten, doc_flatten;
        "-assert", Arg.String add_assert, doc_assert;
        "-nopervasives", Arg.Unit set_no_pervasives, doc_no_pervasives;
        "-target", Arg.String add_target_language, doc_target;
        "-targetpath", Arg.String set_target_path, doc_target_path;
        "-noinit", Arg.Clear init, doc_noinit;
        "-fti", Arg.Set full_type_info, doc_full_type_info;
      ]
      (compile compile_impl)
      errmsg;
  with
    | Misc.Error -> exit 2;;

main ()
