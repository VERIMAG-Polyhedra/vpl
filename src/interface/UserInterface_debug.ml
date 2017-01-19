open CWrappers

module Cs = Cstr.Rat.Positive
module Vec = Cs.Vec
module Var = Vec.V
module CP = CstrPoly.Positive
module Polynomial = CP.Poly

exception ReportHandled

let send : unit -> unit
	= fun () -> () (*
	print_endline "Sending crash log";
	let attach = Netsendmail.wrap_attachment 
		~content_disposition:("attachment", ["filename", Netmime_string.mk_param "log_file"])
		~content_type:("text/plain", [])
		(new Netmime.file_mime_body Config.log_file)
	in
	let email = Netsendmail.compose 
		~to_addrs: [("VPL", "marechalalex@gmail.com")]
		~subject: "VPL crash log"
		~attachments:[ attach ]
		(Printf.sprintf "Report sent") 
	in
	Netsendmail.sendmail ~mailer:"/usr/sbin/sendmail" email
	*)
					
let report : exn -> unit
	= let rec report : exn -> unit
		= let read_char : char -> bool option
			= function
			| 'y' -> Some true
			| 'n' -> Some false
			| _ -> None
		in
		fun e ->
		print_endline "Would you like to automatically send a report? [y/n]";
		match Scanf.bscanf Scanf.Scanning.stdin "%c" read_char with
		| None -> report e
		| Some b -> if b then send() else ()
	in
	fun e ->
	Printf.sprintf "An exception was raised: %s"
		(Printexc.to_string e)
		|> print_endline;
	report e
	
module Interface (Coeff : Scalar.Type) = struct
	
	include Interface(Coeff)
	
	module type Ident_t = sig
		type t

		val compare: t -> t -> int
		val toVar: t -> Var.t
		val to_string: t -> string
	end

	module type Expr_t = sig

		module Ident : Ident_t

		type t 
		
		(** {!val:to_term} may raise this exception. *)
		exception Out_of_Scope

		val to_term: t -> Term.t
	end
	
	(** If you want to use directly the VPL datatypes, instanciate the functor Interface with this module Expr.*)
	module VPL_Expr = struct
		module Ident = struct
			include Var
			let compare x y = cmp x y
			
			let toVar x = x
		end
		
		type t = Term.t
		
		exception Out_of_Scope
		let to_term x = x
	end
	
	module Interface (I : HighLevelDomain)(Expr : Expr_t) = struct
		
		type t = {
			value: I.t;
			name: string;
			}
		
		module Expr = Expr
		
		(** Handles exception report *)
		let handle : 'a Lazy.t -> 'a
			= fun a ->
			try Lazy.force a with 
			| Expr.Out_of_Scope -> Pervasives.raise Expr.Out_of_Scope
			| e -> begin
				report e;
				Pervasives.raise ReportHandled
			end
	
		module UserCond = struct

			type t = 
				| Basic of bool
				| Atom of Expr.t * cmpT * Expr.t
				| BinL of t * binl * t
				| Not of t
			
			let rec to_cond : t -> Cond.t
				= function
				| Basic b -> Cond.Basic b
				| Atom (e1,cmp,e2) -> Cond.Atom (Expr.to_term e1, cmp, Expr.to_term e2)
				| BinL (c1,bl,c2) -> Cond.BinL(to_cond c1, bl, to_cond c2)
				| Not c -> Cond.Not (to_cond c)
		end
		
		module Record = struct
		
			let file = Config.log_file
		
			let out_channel : Pervasives.out_channel ref = ref (Pervasives.open_out file)
		
			let write : string -> unit
				= fun s ->
				Pervasives.output_string !out_channel (s ^ "\n")
		end
		
		module Names = struct
			let next : int ref = ref 0
			
			let mk : unit -> string
				= fun () -> begin
				let res = !next in
				next := !next + 1;
				Printf.sprintf "P%i" res
				end
		end
		
		module Track = struct
			let is_bottom : t -> unit
				= fun p ->
				Printf.sprintf "%s %s" Symbols.s_is_bottom p.name
				|> Record.write
			
			let assume : Cond.t -> t -> string
				= fun cond p ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s %s %s"
					next 
					Symbols.s_assign
					p.name
					Symbols.s_meet
					(Cond.to_string Pol.Var.to_string cond)
				|> Record.write;
				next
			
			let asserts : Cond.t -> t -> unit
				= fun cond p ->
				Printf.sprintf "%s %s in %s"
					Symbols.s_assert
					(Cond.to_string Pol.Var.to_string cond)
					p.name
				|> Record.write
			
			let assign: (Var.t * Term.t) list -> t -> string
				= let assign_to_string : (Var.t * Term.t) list -> string
					= fun l ->
					List.map 
						(fun (v,t) -> Printf.sprintf "%s %s %s" 
							(Var.to_string v)
							Symbols.s_assign
							(Term.to_string Var.to_string t))
						l
					|> String.concat ", "
					|> Printf.sprintf "[%s]"
				in
				fun l p ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s in %s"
					next 
					Symbols.s_assign
					(assign_to_string l)
					p.name
				|> Record.write;
				next
			
			let guassign: (Var.t list) -> Cond.t -> t -> string
				= fun l cond p ->
				let next = Names.mk() in
				Printf.sprintf "guassign not implemented"
				|> Record.write;
				next
				
			let meet : t -> t -> string
				= fun p1 p2 ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s && %s"
					next Symbols.s_assign p1.name p2.name
				|> Record.write;
				next
			
			let join : t -> t -> string
				= fun p1 p2 ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s %s %s"
					next Symbols.s_assign p1.name Symbols.s_join p2.name
				|> Record.write;
				next
			
			let project : Var.t list -> t -> string
				= let print_vars : Var.t list -> string
					= fun vars ->
					String.concat "," (List.map Var.to_string vars)
					|> Printf.sprintf "[%s]"
				in
				fun vars p ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s %s %s"
					next Symbols.s_assign p.name Symbols.s_project (print_vars vars)
				|> Record.write;
				next
			
			let widen : t -> t -> string
				= fun p1 p2 ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s %s %s"
					next Symbols.s_assign p1.name Symbols.s_widen p2.name
				|> Record.write;
				next
			
			let leq : t -> t -> unit
				= fun p1 p2 ->
				Printf.sprintf "%s %s %s" p1.name Symbols.s_includes p2.name
				|> Record.write
			
			let getUpperBound : t -> Term.t -> unit
				= fun p t ->
				Printf.sprintf "%s %s in %s" 
					Symbols.s_upper_bound (Term.to_string Var.to_string t) p.name
				|> Record.write
			
			let getLowerBound : t -> Term.t -> unit
				= fun p t ->
				Printf.sprintf "%s %s in %s" 
					Symbols.s_lower_bound (Term.to_string Var.to_string t) p.name
				|> Record.write
			
			let itvize : t -> Term.t -> unit
				= fun p t ->
				Printf.sprintf "%s %s in %s" Symbols.s_itv (Term.to_string Var.to_string t) p.name
				|> Record.write
			
			let translate : t -> Pol.Cs.Vec.t -> string
				= fun p vec ->
				let next = Names.mk() in
				Printf.sprintf "%s %s %s %s %s"
					next Symbols.s_assign p.name Symbols.s_translate 
					(Pol.Cs.Vec.to_string Pol.Cs.Vec.V.to_string vec)
				|> Record.write;
				next
				
			let mapi : (int -> Pol.Cs.t -> Pol.Cs.t) -> (int -> Pol.Cs.t -> Pol.Cs.t) -> t -> string
				= fun f1 f2 pol ->
				let next = Names.mk() in
				next 
					
		end
		
		(** Defines operators in terms of VPL datastructures. *)
		module BuiltIn = struct
			let mk: string -> I.t -> t
				= fun s p ->
				{value=p ; name = s}
			
			let top : t
				= mk "top" I.top 
		
			let bottom : t
				= mk "bottom" I.bottom
		
			let to_string : (Var.t -> string) -> t -> string
				= fun varPr p -> 
				I.to_string varPr p.value
			
			let is_bottom : t -> bool
				= let is_bottom' : t -> bool
					= fun p -> 
					Track.is_bottom p;
					I.is_bottom p.value
				in
				fun p ->
				lazy (is_bottom' p)
				|> handle
	
			let assume :  Cond.t -> t -> t
				= let assume':  Cond.t -> t -> t
					= fun cond p ->
					let name = Track.assume cond p in
					mk name (I.assume cond p.value)
				in
				fun cond p ->
				lazy (assume' cond p)
				|> handle
		
			let asserts : Cond.t -> t -> bool	
				= let asserts' : Cond.t -> t -> bool
					= fun cond p ->
					Track.asserts cond p;
					I.asserts cond p.value
				in
				fun cond p ->
				lazy (asserts' cond p)
				|> handle 
		
			let assign : (Var.t * Term.t) list -> t -> t
				= let assign' : (Var.t * Term.t) list -> t -> t
					= fun l p ->
					let name = Track.assign l p in
					mk name (I.assign l p.value)
				in
				fun l p ->
				lazy (assign' l p) 
				|> handle 
		
			let guassign: (Var.t list) -> Cond.t -> t -> t
				= let guassign': (Var.t list) -> Cond.t -> t -> t
					= fun l cond p ->
					let name = Track.guassign l cond p in
					mk name (I.guassign l cond p.value)
				in
				fun l cond p ->
				lazy (guassign' l cond p)
				|> handle 
			
			let meet : t -> t -> t
				= let meet' : t -> t -> t
					= fun p1 p2 ->
					let name = Track.meet p1 p2 in
					mk name (I.meet p1.value p2.value)
				in
				fun p1 p2 ->
				lazy (meet' p1 p2) 
				|> handle 
		
			let join : t -> t -> t
				= let join' : t -> t -> t
					= fun p1 p2 ->
					let name = Track.join p1 p2 in
					mk name (I.join p1.value p2.value)
				in
				fun p1 p2 ->
				lazy (join' p1 p2) 
				|> handle 
		
			let project: Var.t list -> t -> t
				= let project': Var.t list -> t -> t
					= fun vars p ->
					let name = Track.project vars p in
					mk name (I.project vars p.value)
				in
				fun vars p ->
				lazy (project' vars p) 
				|> handle 
		
			let widen : t -> t -> t
				= let widen' : t -> t -> t
					= fun p1 p2 ->
					let name = Track.widen p1 p2 in
					mk name (I.widen p1.value p2.value)
				in
				fun p1 p2 ->
				lazy (widen' p1 p2) 
				|> handle 
		
			let leq : t -> t -> bool
				= let leq' : t -> t -> bool
					= fun p1 p2 ->
					Track.leq p1 p2;
					I.leq p1.value p2.value
				in
				fun p1 p2 ->
				lazy (leq' p1 p2) 
				|> handle 
		
			let getUpperBound : t -> Term.t -> Pol.bndT option
				= let getUpperBound' : t -> Term.t -> Pol.bndT option
					= fun p t ->
					Track.getUpperBound p t;
					I.getUpperBound p.value t
				in
				fun p t ->
				lazy (getUpperBound' p t)
				|> handle 
		
			let getLowerBound : t -> Term.t -> Pol.bndT option
				= let getLowerBound' : t -> Term.t -> Pol.bndT option
					= fun p t ->
					Track.getLowerBound p t;
					I.getLowerBound p.value t
				in
				fun p t ->
				lazy (getLowerBound' p t)
				|> handle 
		
			let itvize : t -> Term.t -> Pol.itvT
				= let itvize' : t -> Term.t -> Pol.itvT
					= fun p t ->
					Track.itvize p t;
					I.itvize p.value t
				in
				fun p t ->
				lazy (itvize' p t)
				|> handle 
		                       
			type rep = I.rep  
		                       
			let backend_rep 
				= let backend_rep' : t -> (rep * ((ProgVar.PVar.t -> ProgVar.PVar.t) * (ProgVar.PVar.t -> ProgVar.PVar.t))) option
					= fun p ->
					I.backend_rep p.value
				in
				fun p ->
				lazy (backend_rep' p)
				|> handle 
		
			let translate : t -> Pol.Cs.Vec.t -> t
				= let translate' : t -> Pol.Cs.Vec.t -> t
					= fun p vec ->
					let name = Track.translate p vec in
					mk name (I.translate p.value vec)
				in
				fun p vec ->
				lazy (translate' p vec)
				|> handle 
			
			let mapi : (int -> Pol.Cs.t -> Pol.Cs.t) -> (int -> Pol.Cs.t -> Pol.Cs.t) -> t -> t
				= let map' : (int -> Pol.Cs.t -> Pol.Cs.t) -> (int -> Pol.Cs.t -> Pol.Cs.t) -> t -> t
					= fun f1 f2 p ->
					let name = Track.mapi f1 f2 p in
					mk name (I.mapi f1 f2 p.value)
				in
				fun f1 f2 p ->
				lazy (map' f1 f2 p)
				|> handle 
			
			(** [diff p1 p2] returns a couple of list of polyhedra [(l1,l2)] such that [l1] (resp. [l2]) is a list of polyhedra whose union is [p1 \ p2] (resp. [p2 \ p1]). *)
			let diff : t -> t -> t list * t list
				= let diff' = 
					fun p1 p2 ->
					let swap i j cstr =
						if i = j 
						then Pol.Cs.compl cstr
						else cstr
					in
					let (rep1,rep2) = match backend_rep p1, backend_rep p2 with
						| Some (p1',_), Some (p2',_) -> (p1',p2')
						| _, _ -> Pervasives.failwith "diff"
					in
					let id _ c = c in
					let p1_compls = List.mapi
						(fun i _ -> mapi id (swap i) p1)
						(Pol.get_ineqs rep1)
					and p2_compls = List.mapi
						(fun i _ -> mapi id (swap i) p2)
						(Pol.get_ineqs rep2)
					in
					List.map (meet p1) p2_compls,
					List.map (meet p2) p1_compls 
				in 
				fun p1 p2 ->
				lazy (diff' p1 p2)
				|> handle 
		end
		
		include BuiltIn
		
		(** Defines operators in terms of the User datastructures. *)
		module User = struct
			include BuiltIn
			
			let assume: UserCond.t -> t -> t
				= fun c p ->
				assume (UserCond.to_cond c) p

			let asserts: UserCond.t -> t -> bool
				= fun c p ->
				asserts (UserCond.to_cond c) p

			let assign: (Expr.Ident.t * Expr.t) list -> t -> t
				= fun l p ->
				assign 
					(List.map (fun (v,e) -> Expr.Ident.toVar v, Expr.to_term e) l) 
					p
			
			let project: Expr.Ident.t list -> t -> t
				= fun vars p ->
				let vars' = List.map Expr.Ident.toVar vars in
				project vars' p
				
			let guassign: (Expr.Ident.t list) -> UserCond.t -> t -> t
				= fun vl c p ->
				guassign (List.map Expr.Ident.toVar vl) (UserCond.to_cond c) p
			
			let getUpperBound : t -> Expr.t -> Pol.bndT option
				= fun p expr ->
				getUpperBound p (Expr.to_term expr)
			
			let getLowerBound : t -> Expr.t -> Pol.bndT option
				= fun p expr ->
				getLowerBound p (Expr.to_term expr)
			
	  		let itvize : t -> Expr.t -> Pol.itvT
	  			= fun p expr ->
				itvize p (Expr.to_term expr)
		end
	end
end


