(*----------------------------------------------------------------------(C)-*)
(* Copyright (C) 2006-2012 Konstantin Korovin and The University of Manchester. 
   This file is part of iProver - a theorem prover for first-order logic.

   iProver is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.
   iProver is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
   See the GNU General Public License for more details.
   You should have received a copy of the GNU General Public License
   along with iProver.  If not, see <http://www.gnu.org/licenses/>.         *)
(*----------------------------------------------------------------------[C]-*)





open Options
open Statistics 
open Lib

open Logic_interface

type clause = Clause.clause
type symbol = Symbol.symbol

let symbol_db_ref  = Parser_types.symbol_db_ref
let term_db_ref    = Parser_types.term_db_ref
let top_term       = Parser_types.top_term

(*
let add_fun_term_list symb list = 
  TermDB.add_ref (Term.create_fun_term symb list) term_db_ref


let add_fun_term_args symb args = 
  TermDB.add_ref (Term.create_fun_term_args symb args) term_db_ref
*)

let prop_simp clause_list = 
	(* debug *)
	 (* List.iter 
		 (fun c -> 
					Format.printf "Prep: %a@.\n" (TstpProof.pp_clause_with_source false) c; 	
       Prop_solver_exchange.add_clause_to_solver c;
     )
		clause_list;
		*)
   List.iter 
    Prop_solver_exchange.add_clause_to_solver clause_list;
  (if ((Prop_solver_exchange.solve ()) = PropSolver.Unsat)
   then 
      ((* Format.eprintf "Unsatisfiable after solve call in Preprocess.prop_sim@."; *)
       (* Raise separate exception, since BMC1 must continue if
	  simplified and must not continue if solver is in invalid state *)
       (* raise PropSolver.Unsatisfiable *)
       raise Prop_solver_exchange.Unsatisfiable)
   else ());
  let simplify_clause rest clause = 
    (Prop_solver_exchange.prop_subsumption clause)::rest
  in
  List.fold_left simplify_clause [] clause_list



(*------Non-equational to Equational (based on input options)-----------*) 

module SymbKey = 
  struct
    type t    = symbol
    let equal = (==)
    let hash  = Symbol.get_fast_key 
  end 

module PredToFun = Hashtbl.Make (SymbKey)
  

let pred_to_fun_symb pred_to_fun_htbl pred = 
  try 
    PredToFun.find pred_to_fun_htbl pred
  with 
    Not_found ->
      let new_symb_name = ("$$iProver_FunPred_"^(Symbol.get_name pred)) in
      let new_type = 
	match (Symbol.get_stype_args_val pred) with
	|Def(old_args, old_val) ->
            Symbol.create_stype old_args Symbol.symb_bool_type
	|Undef -> 
	    Symbol.create_stype [] Symbol.symb_default_type    
      in
      let fun_symb = 
	Symbol.create_from_str_type_property
	  new_symb_name new_type Symbol.FunPred in
      let added_fun_symb = SymbolDB.add_ref fun_symb symbol_db_ref in
      PredToFun.add pred_to_fun_htbl pred added_fun_symb;
      added_fun_symb

 
let pred_to_fun_atom pred_to_fun_htbl atom =
  match atom with 
  |Term.Fun (pred,args,_) -> 
      if not (pred == Symbol.symb_typed_equality)
      then 
	let fun_symb = pred_to_fun_symb pred_to_fun_htbl pred in
	let fun_term = add_fun_term_args fun_symb args in 
	let eq_term  = add_typed_equality_sym Symbol.symb_bool_type fun_term top_term in
	eq_term
      else
	atom
  |_ -> failwith "pred_to_fun_atom should not be var"


let pred_to_fun_lit pred_to_fun_htbl lit =
  let new_lit = Term.apply_to_atom (pred_to_fun_atom pred_to_fun_htbl) lit in 
  TermDB.add_ref new_lit term_db_ref
        
      

let pred_to_fun_clause pred_to_fun_htbl clause = 
  let new_lits = 
    List.map
      (pred_to_fun_lit pred_to_fun_htbl)
      (Clause.get_literals clause) in
	let tstp_source = Clause.tstp_source_non_eq_to_eq clause in		
  let new_clause = create_clause tstp_source new_lits in
  (* Clause.assign_non_eq_to_eq_history new_clause clause; *)
  
  new_clause

(* *)
let res_prep_options () = 
	{!current_options
	with 
	(*----Resolution---------*)
	resolution_flag = true;
	
	res_prop_simpl_new = true;
	res_prop_simpl_given = true;
	(*switch between simpl and priority queues*)
	(* TO DO  Queues options like in Inst. *)
	res_passive_queue_flag = true;
	res_pass_queue1 = [Cl_Num_of_Lits false; Cl_Num_of_Symb false];
	res_pass_queue2 = [Cl_Num_of_Lits false; Cl_Num_of_Symb false];
	res_pass_queue1_mult = 150;
	res_pass_queue2_mult = 150;
	
	res_forward_subs = Subs_Full;
	res_backward_subs = Subs_Full;
	res_forward_subs_resolution = true;
	(*  res_forward_subs_resolution    = true; exp later for sat *)
	(* res_backward_subs_resolution   = false; *)
	res_backward_subs_resolution = true;
	res_time_limit = 60.0;
	}
	
	
let res_prep clause_list = 
	let old_options = !current_options in 
	current_options := res_prep_options ();
	let module ResInput =
	    struct
				let res_module_name = "Res prep"
				let input_clauses = clause_list
				let is_res_prepocessing = true 
			end 
	 in
			let module ResM = Discount.Make (ResInput) in
			let new_clauses = ResM.res_prep () in 
			ResM.clear_all ();
			current_options := old_options;
			new_clauses
			
			    
let preprocess clause_list =
  let current_list = ref clause_list in
  (if !current_options.non_eq_to_eq 
  then 
    (
     let pred_to_fun_htbl = PredToFun.create (SymbolDB.size !symbol_db_ref) in
     current_list := 
       (List.map (pred_to_fun_clause pred_to_fun_htbl) !current_list)
    )
  else ()
  ); 
 (if  !current_options.prep_gs_sim 
 then 
	current_list := prop_simp !current_list
 else ());  
 (if !current_options.prep_res_sim 
 then
  current_list := res_prep !current_list
 else ()
	);
 (match !current_options.ground_splitting with
  |Split_Input |Split_Full ->    
      let split_result = 
	(Splitting.ground_split_clause_list !current_list) in
      incr_int_stat 
	(Splitting.get_num_of_splits split_result) num_of_splits; 
      incr_int_stat 
	(Splitting.get_num_of_split_atoms split_result) num_of_split_atoms;	
      current_list:=Splitting.get_split_list split_result
  |Split_Off-> ()
    );
  !current_list 
    
