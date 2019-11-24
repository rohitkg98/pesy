(* NB: This needs to be pure OCaml (no Base!), since we need this in order to build
   Base. *)

(* This module generates lookup tables to detect integer overflow when calculating integer
   exponents.  At index [e], [table.[e]^e] will not overflow, but [(table[e] + 1)^e]
   will. *)

type mode = Normal | Atomic of { out_fn : string; tmp_fn : string }

let oc, mode =
  match Sys.argv with
  | [|_|] -> (stdout, Normal)
  | [|_; "-o"; out_fn|]
  | [|_; "-atomic"; "-o"; out_fn|] ->
    (* Always produce the file atomically, we just have this option to remember that we
       need to do it *)
    let tmp_fn, oc =
      Filename.open_temp_file
        ~temp_dir:(Filename.dirname out_fn)
        "generate_pow_overflow_bounds" ".ml.tmp"
    in
    (oc, Atomic { out_fn; tmp_fn })
  | _ -> failwith "bad command line arguments"

module Big_int = struct
  include Big_int
  type t = big_int
  let (>)  = gt_big_int
  let (<=) = le_big_int
  let (^)  = power_big_int_positive_int
  let (-)  = sub_big_int
  let (+)  = add_big_int
  let one  = unit_big_int
  let sqrt = sqrt_big_int
  let to_string = string_of_big_int
end

module Array = StdLabels.Array

type generated_type =
  | Int
  | Int32
  | Int63
  | Int64

let max_big_int_for_bits bits =
  let shift = bits - 1 in (* sign bit *)
  Big_int.((shift_left_big_int one shift) - one)
;;

let safe_to_print_as_int =
  let int31_max = max_big_int_for_bits 31 in
  fun x -> Big_int.(x <= int31_max)

let format_entry typ b =
  let s = Big_int.to_string b in
  match typ with
  | Int ->
    if safe_to_print_as_int b
    then s
    else Printf.sprintf "Caml.Int64.to_int %sL" s
  | Int32 -> s ^ "l"
  | Int63
  | Int64 -> s ^ "L"

let bits = function
  | Int   -> assert false (* architecture dependent *)
  | Int32 -> 32
  | Int63 -> 63
  | Int64 -> 64

let max_val typ = max_big_int_for_bits (bits typ)

let name = function
  | Int   -> "int"
  | Int32 -> "int32"
  | Int63 -> "int63_on_int64"
  | Int64 -> "int64"

let ocaml_type_name = function
  | Int   -> "int"
  | Int32 -> "int32"
  | Int63
  | Int64 -> "int64"

let generate_negative_bounds = function
  | Int   -> false
  | Int32 -> false
  | Int63 -> false
  | Int64 -> true

let highest_base exponent max_val =
  let open Big_int in
  match exponent with
  | 0 | 1 -> max_val
  | 2 -> sqrt max_val
  | _ ->
    let rec search possible_base =
      if possible_base ^ exponent > max_val then
        begin
          let res = possible_base - one in
          assert (res ^ exponent <= max_val);
          res
        end
      else
        search (possible_base + one)
    in
    search one
;;

type sign = Pos | Neg

let pr fmt = Printf.fprintf oc (fmt ^^ "\n")

let gen_array ~typ ~bits ~sign ~indent =
  let pr fmt = pr ("%*s" ^^ fmt) indent "" in
  let max_val = max_big_int_for_bits bits in
  let pos_bounds = Array.init 64 ~f:(fun i -> highest_base i max_val) in
  let bounds =
    match sign with
    | Pos -> pos_bounds
    | Neg -> Array.map pos_bounds ~f:Big_int.minus_big_int
  in
  pr "[| %s" (format_entry typ bounds.(0));
  for i = 1 to Array.length bounds - 1 do
    pr ";  %s" (format_entry typ bounds.(i))
  done;
  pr "|]";
;;


let gen_bounds typ =
  pr "let overflow_bound_max_%s_value : %s =" (name typ) (ocaml_type_name typ);
  (match typ with
   | Int -> pr "  (-1) lsr 1"
   | _   -> pr "  %s" (format_entry typ (max_val typ)));
  pr "";

  let array_name typ sign =
    Printf.sprintf "%s_%s_overflow_bounds" (name typ)
      (match sign with Pos -> "positive" | Neg -> "negative")
  in

  pr "let %s : %s array =" (array_name typ Pos) (ocaml_type_name typ);
  (match typ with
   | Int ->
     pr "  match Int_conversions.num_bits_int with";
     pr "  | 32 -> Array.map %s ~f:Caml.Int32.to_int" (array_name Int32 Pos);
     pr "  | 63 ->";
     gen_array ~typ ~bits:63 ~sign:Pos ~indent:4;
     pr "  | 31 ->";
     gen_array ~typ ~bits:31 ~sign:Pos ~indent:4;
     pr "  | _ -> assert false"
   | _ ->
     gen_array ~typ ~bits:(bits typ) ~sign:Pos ~indent:2);
  pr "";

  if generate_negative_bounds typ then begin
    pr "let %s : %s array =" (array_name typ Neg) (ocaml_type_name typ);
    gen_array ~typ ~bits:(bits typ) ~sign:Neg ~indent:2
  end;
;;

let () =
  pr "(* This file was autogenerated by %s *)" Sys.argv.(0);
  pr "";
  pr "open! Import";
  pr "";
  pr "module Array = Array0";
  pr "";
  pr "(* We have to use Int64.to_int_exn instead of int constants to make";
  pr "   sure that file can be preprocessed on 32-bit machines. *)";
  pr "";
  gen_bounds Int32;
  gen_bounds Int;
  gen_bounds Int63;
  gen_bounds Int64;
;;

let () =
  match mode with
  | Normal -> ()
  | Atomic { tmp_fn; out_fn } ->
    close_out oc;
    Sys.rename tmp_fn out_fn
