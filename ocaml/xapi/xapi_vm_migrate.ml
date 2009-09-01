(* ------------------------------------------------------------------

   Copyright (c) 2006, 2007 Xensource Inc

   Contacts: David Scott     <dave.scott@xensource.com>
             Vincent Hanquez <vincent@xensource.com>

   Code to control VM migration

   ------------------------------------------------------------------- *)

(* We only currently support within-pool live or dead migration.
   Unfortunately in the cross-pool case, two hosts must share the same SR and
   co-ordinate tapdisk locking. We have not got code for this. 
*)

open Pervasiveext
open Printf
open Vmopshelpers

module DD=Debug.Debugger(struct let name="xapi" end)
open DD

open Client

(* ------------------------------------------------------------------- *)
(* Part 1: utility functions                                           *)

exception Remote_failed of string

(** Functions to synchronise between the sender and receiver via binary messages of the form:
    00 00 -- success
    11 22 <0x1122 bytes of data> -- failure, with error message
    Used rather than the API for signalling between sender and receiver to avoid having to
    go through the master and interact with locking. *)
module Handshake = struct
  type result =
      | Success
      | Error of string
  let string_of_result = function
    | Success -> "Success"
    | Error x -> "Error: " ^ x

  (** Receive a 'result' from the remote *)
  let recv (s: Unix.file_descr) : result =
    let buf = String.make 2 '\000' in
    (try Unixext.really_read s buf 0 (String.length buf)
     with _ -> raise (Remote_failed "unmarshalling result code from remote"));

    let len = int_of_char buf.[0] lsl 8 lor (int_of_char buf.[1]) in
    if len = 0
    then Success
    else (let msg = String.make len '\000' in
	  (try Unixext.really_read s msg 0 len
	   with _ -> raise (Remote_failed "unmarshalling error message from remote"));
	  Error msg)

  (** Expects to receive a success code from the server, throws an exception otherwise *)
  let recv_success (s: Unix.file_descr) : unit = match recv s with
    | Success -> ()
    | Error x -> raise (Remote_failed ("error from remote: " ^ x))

  (** Transmit a 'result' to the remote *)
  let send (s: Unix.file_descr) (r: result) =
    let len = match r with
      | Success -> 0 | Error msg -> String.length msg in
    let buf = String.make (2 + len) '\000' in
    buf.[0] <- char_of_int ((len lsr 8) land 0xff);
    buf.[1] <- char_of_int ((len lsr 0) land 0xff);
    (match r with
     | Success -> () | Error msg -> String.blit msg 0 buf 2 len);
    if Unix.write s buf 0 (len + 2) <> len + 2
    then raise (Remote_failed "writing result to remote")

end

let vm_migrate_failed vm source dest msg = 
  raise (Api_errors.Server_error(Api_errors.vm_migrate_failed,
				 [ Ref.string_of vm; Ref.string_of source; Ref.string_of dest; msg ]))

let migration_failure vm source dest exn = match exn with
  | Api_errors.Server_error(_, _) -> raise exn (* leave it alone *)
  | _ -> vm_migrate_failed vm source dest (ExnHelper.string_of_exn exn)

let want_failure __context vm num = 
  let other_config = Db.VM.get_other_config ~__context ~self:vm in
  List.mem_assoc Xapi_globs.migration_failure_test_key other_config &&
    (int_of_string (List.assoc Xapi_globs.migration_failure_test_key other_config) = num)

(* Extra paths in xenstore to watch during migration *)
let extra_debug_paths __context vm = 
  let other_config = Db.VM.get_other_config ~__context ~self:vm in
  if List.mem_assoc Xapi_globs.migration_extra_paths_key other_config
  then Stringext.String.split ',' (List.assoc Xapi_globs.migration_extra_paths_key other_config)
  else []

(* MTC: Routine to report migration progress via task and events *)
let migration_progress_cb ~__context vm_migrate_failed ~vm progress =
  TaskHelper.set_progress ~__context progress;
  Mtc.event_notify_task_status ~__context ~vm ~status:`pending progress;
  if Mtc.event_check_for_abort_req ~__context ~self:vm then
    vm_migrate_failed "An external abort event was detected."

(* MTC: This function is called when the migration code is suspending a domain
   (going from background to foreground mode). For MTC protected VMs, it
   requires that an external agent acknowledge the transition prior to 
   continuing. *)
let migration_suspend_cb ~xal ~xc ~xs ~__context vm_migrate_failed ~self domid reason =
  Mtc.event_notify_entering_suspend ~__context ~self;

  let ack = Mtc.event_wait_entering_suspend_acked ~timeout:60. ~__context ~self in

  (* If we got the ack, then proceed to shutdown the domain with the suspend
     reason.  If we failed to get the ack, then raise an exception to abort
     the migration *)
  if (ack = `ACKED) then 
    Vmops.clean_shutdown_with_reason ~xal ~__context ~self domid Domain.Suspend
  else 
    vm_migrate_failed "Failed to receive suspend acknowledgement within timeout period or an abort was requested."

(* ------------------------------------------------------------------- *)
(* Part 2: transmitter and receiver functions                          *)

(* Note on crashes during migration:
   We don't clean up crashed domains on the sending side, instead we defer to the event
   thread and allow per-VM actions_after_crash.
   By contrast we clean up domains on the receiving side on failure, since they never
   became associated with the VM database record and are therefore invisible to the 
   event thread. *)

(* Called with a valid session ID and with VDI locks released. *)
let transmitter ~xal ~__context is_localhost_migration fd vm_migrate_failed host remote_session_id vm xc xs live =
  let domid = Helpers.domid_of_vm ~__context ~self:vm in
  let hvm = Helpers.has_booted_hvm ~__context ~self:vm in

  (* Enumerate the disk devices in advance. Only pre-shutdown disks marked as RW *)
  let vbds = Db.VM.get_VBDs ~__context ~self:vm in
  let vbds = List.filter (fun self -> Db.VBD.get_currently_attached ~__context ~self) vbds in
  let vbds = List.filter (fun self -> Db.VBD.get_mode ~__context ~self = `RW) vbds in
  let devices = List.map (fun self -> Xen_helpers.device_of_vbd ~__context ~self) vbds in

  let vdis = 
    List.map
      (fun self -> Db.VBD.get_VDI ~__context ~self)
      (List.filter (fun vbd -> not(Db.VBD.get_empty ~__context ~self:vbd)) vbds) in

  let extra_debug_paths = extra_debug_paths __context vm in

  if want_failure __context vm 1 then begin
    debug "Simulating failure before calling Domain.suspend";
    failwith "Simulating failure before calling Domain.suspend";
  end;  

  (* Confirm that the remote was able to construct the new domain, attach disks
     and VIFs etc before we bring our healthy domain down *)
  begin match Handshake.recv fd with
  | Handshake.Success   -> ()
  | Handshake.Error msg ->
    error "cannot transmit vm to host: %s" msg;
    vm_migrate_failed msg
  end;
  (* <-- [1] Synchronisation point *)

  (* We assume that if the Domain.suspend call fails then the remote also
     errors out and cleans up its proto-domain. If we fail locally then either
     a) our domain is still alive: do nothing; or
     b) our domain has shutdown: rely on the event thread to clean up after us.
     In particular, if we have crashed then the after_crash action will be respected.
     If we suspended but the remote failed, the event thread will perform a
     hard_shutdown *)
  debug "Sender 4. calling Domain.suspend (domid = %d; hvm = %b)" domid hvm;
  try
    if want_failure __context vm 2 then begin
      debug "Simulating domain crash during Domain.suspend";
      Xc.domain_shutdown xc domid Xc.Crash;
      raise (Vmops.Domain_shutdown_for_wrong_reason Xal.Crashed)
    end;

    (* PCI: The following code only does anything if PCI devices have been passed-through
       which is an unsupported configuration. *)
    let pci_hotunplug_time = try float_of_string (List.assoc "pci-hotunplug-time" (Db.VM.get_other_config ~__context ~self:vm)) with _ -> 0.8 in
    let pci_devices_to_unplug = ref [] in (* XXX: currently only support 1 due to xenstore protocol *)
    let pci_unplug_initiated_already = ref false in
    let pci_unplug_initiate_noexn () = 
      Helpers.log_exn_continue "pci_unplug_initiate"
	(fun () ->
	   if not (!pci_unplug_initiated_already) then begin
	     pci_unplug_initiated_already := true;
	     debug "looking for PCI devices to hot unplug";
	     let devices = Device.PCI.list ~xc ~xs domid in
	     if List.length devices > 1 then warn "We can only handle one PCI device during migration!";
	     if List.length devices > 0 then begin
	       let (id, device) = List.hd devices in
	       let (domain, bus, dev, func) = device in
	       debug "requesting unplug of %.4x:%.2x:%.2x.%.1x" domain bus dev func;
	       Device.PCI.unplug ~xc ~xs device domid (-1);
	       pci_devices_to_unplug := [ device ]
	     end	
	   end) () in
    let pci_unplug_wait_noexn () = 
      Helpers.log_exn_continue "pci_unplug_wait"
	(fun () ->
	   debug "waiting for PCI hotunplug to complete";
	   List.iter (fun device -> 
			let (domain, bus, dev, func) = device in
			debug "synchronising with unplug of %.4x:%.2x:%.2x.%.1x" domain bus dev func;
			Device.PCI.unplug_wait ~xc ~xs domid
		     ) !pci_devices_to_unplug) () in


    (* MTC: We want to be notified when libxc's xc_domain_save suspends the domain
     *      to go from background to foreground mode.  Therefore, we provide the
     *      MTC callback routine here to notify MTC software and must wait for 
     *      MTC software to acknowlege that it has transitioned into foreground
     *      before allowing it continued.
     *)
    Domain.suspend ~xc ~xs ~hvm domid fd (if live then [ Domain.Live ] else [])
      ~progress_callback:(fun x -> 
			    debug "migration_progress = %.2f" x;
			    if x > pci_hotunplug_time then pci_unplug_initiate_noexn ();
			    migration_progress_cb ~__context vm_migrate_failed ~vm (x *. 0.95)) 
      (fun () -> 
	 pci_unplug_initiate_noexn(); (* just in case *)
	 pci_unplug_wait_noexn ();
	 migration_suspend_cb ~xal ~xc ~xs ~__context vm_migrate_failed ~self:vm domid Domain.Suspend);

    (* <-- [2] Synchronisation point *)

    (* At this point our domain has shutdown with reason 'suspend' and the
       memory image has been transmitted. We assume that we cannot recover this domain
       and that it must be destroyed. We must make sure we detect failure in the 
       remote to complete the admin and set the VM to halted if this happens. *)
    Stats.time_this "VM migration downtime" (fun () ->
    (* Depending on where the exn in the try block happens, we may or may not want to
       deactivate VDIs in the finally clause. In the case of a non-localhost migration
       we initialise deactivate_in_finally_clause to true; for localhost migration we never
       want to do any deactiving so we initialise it to false right away *)
    let deactivate_in_finally_clause = ref (not is_localhost_migration) in
    let detach_in_finally_clause = ref true in
    finally 
      (fun () ->
	 try
	   if want_failure __context vm 3 then begin
	     debug "Simulating failure just after Domain.suspend";
	     failwith "Simulating failure just after Domain.suspend";
	   end;

	   (* Flush disk blocks and signal the remote when we're ready *)
	   debug "Sender 5. waiting for blocks to flush";
	   Domain.hard_shutdown_all_vbds ~xc ~xs ~extra_debug_paths devices;

	   (* Deactivate VDIs, allow errors to propogate if deactivate fails - not much we can do here.
	      Since we don't have a force deactivate or anything like that, then you're back to using
	      an out-of-band mechanism to deactivate your disks..

	      If doing a localhost migration then we supress this step
	   *)
	   (* If we get an exception up to this point then the finally clause will attempt the deactivate *)
	   deactivate_in_finally_clause := false;
	   if is_localhost_migration then
	     debug "Sender 5a. Note: NOT deactiving VDIs because this is a localhost migrate"
	   else begin
			debug "Sender 5a. Deactivating VDIs";
			List.iter (fun vdi -> Storage_access.VDI.deactivate ~__context ~self:vdi) vdis;
		end;

	   debug "Sender 6. signalling remote to unpause";
	   (* <-- [3] Synchronisation point *)
	   Handshake.send fd Handshake.Success;
	   (* At any time from now on, the remote VM is unpaused and VM.domid, VM.resident_on
	      both change. We mustn't rely on their values. *)

		begin
			debug "Sender 6a. Detaching VDIs";
			List.iter (fun vdi ->
				Helpers.log_exn_continue ("failed to detach vdi: " ^ (Ref.string_of vdi))
					(fun () -> Storage_access.VDI.detach ~__context ~self:vdi) ())
			vdis;
			detach_in_finally_clause := false;
		end;


	   (* Now send across the RRD *)
	   (try Monitor_rrds.migrate_push ~__context (Db.VM.get_uuid ~__context ~self:vm) host with e ->
	     debug "Caught exception while trying to push rrds: %s" (ExnHelper.string_of_exn e);
	     log_backtrace ());

	   (* We mustn't return to our caller (and release locks) until the remote confirms
	      that it has reparented the VM by setting resident-on, domid *)
	   debug "Sender 7. waiting for all-clear from remote";
	   (* <-- [4] Synchronisation point *)
	   Handshake.recv_success fd
	 with e ->
	   (* This should only happen if the receiver has died *)
	   let msg = Printf.sprintf "Caught exception %s at last minute during migration"
	     (ExnHelper.string_of_exn e) in
	   debug "%s" msg; error "%s" msg;
	   Xapi_vm_lifecycle.force_state_reset ~__context ~self:vm ~value:`Halted;
	   vm_migrate_failed msg
      )
      (fun () ->
	 debug "Sender cleaning up by destroying remains of local domain";
	 if !deactivate_in_finally_clause then
		List.iter (fun vdi -> Storage_access.VDI.deactivate ~__context ~self:vdi) vdis;
	 if !detach_in_finally_clause then
		List.iter (fun vdi -> Storage_access.VDI.detach ~__context ~self:vdi) vdis;
	 let preserve_xs_vm = (Helpers.get_localhost ~__context = host) in
	 Vmops.destroy_domain ~preserve_xs_vm ~clear_currently_attached:false ~detach_devices:(not is_localhost_migration)
	   ~deactivate_devices:(!deactivate_in_finally_clause) ~__context ~xc ~xs ~self:vm domid)
) (* Stats.timethis *)
  with 
    (* If the domain shuts down incorrectly, rely on the event thread for tidying up *)
  | Vmops.Domain_shutdown_for_wrong_reason Xal.Crashed ->
      debug "Domain crashed while suspending";
      vm_migrate_failed "Domain crashed while suspending"
  | Vmops.Domain_shutdown_for_wrong_reason r ->
      let msg = Printf.sprintf "Domain attempted to %s while suspending"
	(Xal.string_of_died_reason r) in
      debug "%s" msg;
      vm_migrate_failed msg
  | Api_errors.Server_error(_, _) as e -> raise e
  | e -> vm_migrate_failed (ExnHelper.string_of_exn e)


(* Called with the VM locked (either by us or by the sender, depending on whether
   we are migrating to localhost or not) *)
let receiver ~__context ~localhost is_localhost_migration fd vm xc xs memory_required_kib =
  let snapshot = Helpers.get_boot_record ~__context ~self:vm in

  (* MTC: If this is a protected VM, then return the peer VM configuration
   * for instantiation (the destination VM where we'll migrate to).  
   * Otherwise, it returns the current VM (which is the unmodified XAPI
   * behavior).
   *)
  let vm = Mtc.get_peer_vm_or_self ~__context ~self:vm in

  (* NOTE: we do not activate at this stage that comes later in migrate protocol,
     when transmitter tells us that he's flushed the blocks and deactivated.
  *)
  let needed_vdis = Vmops.get_VDIs_required_on_resume ~__context ~vm in
  debug "Receiver 4a. Attaching VDIs";
  let results = List.map
    (fun (vdi,mode) -> try Storage_access.VDI.attach ~__context ~self:vdi ~mode; None with exn -> Some exn)
    needed_vdis in
  (* Check if one VDI.attach fails. If it is the case, detach all the sucessfully attached VBD. *)
  List.iter 
    (function Some exn -> debug "Receiver caught exception during VDI attach: %s" (ExnHelper.string_of_exn exn) | None -> ())
    results;
  if List.exists (function Some exn -> true | None -> false) results then begin
    let Some exn = List.find (function Some exn -> true | None -> false) results in
    Handshake.send fd (Handshake.Error (ExnHelper.string_of_exn exn));
    List.iter2 (fun (vdi,_) r -> if r = None then Storage_access.VDI.detach ~__context ~self:vdi) needed_vdis results;
    raise exn;
  end;
  let detach_all_vdis () =
     debug "Detaching all the attached VDIs";
     List.iter (fun (vdi,_) -> Storage_access.VDI.detach ~__context ~self:vdi) needed_vdis in
  try

  (* CA-13785:
     Populating xenstore device trees requires that we lookup the major, minor numbers of the device;
     but in the case that an SR supports activate we mustn't touch the device (even to lookup major/minor number)
     until after the activate call has been made. However, rather re-ordering the migrate code in all cases
     [which puts more "things that could go wrong" after the point-of-no-return] we only delay the device creation
     if any VDIs are in SRs that have the VDI_ACTIVATE capability. This means that this change should not impact
     Miami testing, since none of the Miami SR backends to be shipped in product support VDI_ACTIVATE.

     !!! At some point in the future we would like to remove this special casing in favour or something more sensible !!!

  *)
  let delay_device_create_until_after_activate =
    List.fold_left
      (fun env (vdi,_) -> env || (Storage_access.VDI.check_enclosing_sr_for_capability __context Smint.Vdi_activate vdi))
      false needed_vdis in

  (* We create the domain using this as a template: *)
  debug "Receiver 4b. Creating new domain";
  let domid = Vmops.create ~__context ~xc ~xs ~self:vm snapshot () in
  let needed_vifs = Vm_config.vifs_of_vm ~__context ~vm domid in

  (try
     Memory_control.allocate_memory_for_domain ~__context ~xc ~xs ~initial_reservation_kib:memory_required_kib domid;

     if not delay_device_create_until_after_activate then
       begin
	 debug "Receiver 5. Calling Vmops._restore_devices (domid = %d)" domid;
	 Vmops._restore_devices ~__context ~xc ~xs ~self:vm snapshot fd domid needed_vifs
       end
     else
       debug "Note: receiver _not_ calling _restore_devices yet, because at least one SR has activate capability -- we will call _restore_devices after activate instead";
     if want_failure __context vm 4 then begin
       debug "Simulating failure just before restore";
       failwith "Simulating failure just before restore (eg out of memory, couldn't attach disk)";
     end;
     Handshake.send fd Handshake.Success
   with exn ->
     Handshake.send fd (Handshake.Error (ExnHelper.string_of_exn exn));
     Vmops.destroy_domain ~__context ~clear_currently_attached:false ~deactivate_devices:false ~detach_devices:(not is_localhost_migration) ~xc ~xs ~self:vm domid;
     raise exn);
  
  (* <-- [1] Synchronisation point *)
  
  (* If our restore fails, clean up and abort *)
  (try 
     Vmops._restore_domain ~__context ~xc ~xs ~self:vm snapshot fd domid needed_vifs
   with e ->
       error "Caught exception during domain restore: %s" (ExnHelper.string_of_exn e);
       (* This domain never got associated with the database record so we destroy it ourselves *)
       Vmops.destroy_domain ~clear_currently_attached:false ~deactivate_devices:false ~detach_devices:(not is_localhost_migration) ~__context ~xc ~xs ~self:vm domid;
       raise e);

  (* <-- [2] Synchronisation point *)  
  if want_failure __context vm 5 then begin
    debug "Simulating domain crash after restore";
    Xc.domain_shutdown xc domid Xc.Crash;
    (* Continue on, like would happen if we crashed asynchronously *)
  end;

  (* Wait for the sender to flush its disk blocks. If the sender dies or otherwise
     screws up at this point then we can still recover the domain here (there's
     no going back!) *)
  debug "Receiver 6. waiting for remote to flush disk blocks and to signal us to unpause";
  (try 
     Handshake.recv_success fd
   with e ->
     (* This should be very very rare. *)
     error "Sending machine failed to flush disk blocks: aborting";
     Vmops.destroy_domain ~clear_currently_attached:false ~deactivate_devices:false ~detach_devices:(not is_localhost_migration) ~__context ~xc ~xs ~self:vm domid;
     raise e);
  (* <-- [3] Synchronisation point *)
  
  (try
     (* Activate devices, allowing exceptions to propogate since if we cannot activate then the migrate
	fails  *)
     if is_localhost_migration then
       debug "Receiver 7a. Note: NOT activating VDIs (because this is localhost migrate)"
     else
       begin
	 debug "Receiver 7a. Activating VDIs";
	 List.iter (fun (vdi,_) -> Storage_access.VDI.activate ~__context ~self:vdi) needed_vdis
       end;
     
     if delay_device_create_until_after_activate then
       begin
	 debug "Receiver 7a1. Calling Vmops._restore_devices (domid = %d) [doing this now because we call after activate]" domid;
	 Vmops._restore_devices ~__context ~xc ~xs ~self:vm snapshot fd domid needed_vifs
       end;
   with e ->
     error "Caught exception during activate: %s" (ExnHelper.string_of_exn e);
     if not is_localhost_migration then
       List.iter (fun (vdi,_) -> Storage_access.VDI.deactivate ~__context ~self:vdi) needed_vdis;
     Vmops.destroy_domain ~clear_currently_attached:false ~deactivate_devices:false ~detach_devices:(not is_localhost_migration) ~__context ~xc ~xs ~self:vm domid;
     raise e);

  debug "Receiver 7b. unpausing domain";
  Domain.unpause ~xc domid;

  Vmops.plug_pcidevs ~__context ~vm domid;

  Db.VM.set_domid ~__context ~self:vm ~value:(Int64.of_int domid);
  Helpers.call_api_functions ~__context
    (fun rpc session_id -> Client.VM.atomic_set_resident_on rpc session_id vm localhost);

  (* MTC: Normal XenMotion migration does not change the VM's power state *)
  Mtc.update_vm_state_if_necessary ~__context ~vm;

  Memory_control.balance_memory ~xc ~xs;

  TaskHelper.set_progress ~__context 1.;
  
  debug "Receiver 8. signalling sender that we're done";
  Handshake.send fd Handshake.Success;
  (* <-- [4] Synchronisation point *)
  debug "Receiver 9a Success"
  with e ->
    error "Receiver 9b Failure";
    detach_all_vdis ();
    raise e

(* ------------------------------------------------------------------- *)
(* Part 3: setup code (connecting, authenticating, locking)            *)

let pool_migrate_nolock  ~__context ~vm ~host ~options =
  let destination_enabled = Db.Host.get_enabled ~__context ~self:host in
  let _ =
    if not destination_enabled
    then raise (Api_errors.Server_error (Api_errors.host_disabled, [Ref.string_of vm]))
  in
  let vm_r = Db.VM.get_record ~__context ~self:vm in
  let localhost = Helpers.get_localhost ~__context in

  (* transmitter can see this is localhost migration if he is same host as the specified destination host *)
  let localhost_migration = (host = localhost) in

  (* check if the flags are similar *)
  let localcpu = List.hd (Db.Host.get_host_CPUs ~__context ~self:localhost)
  and destcpu = List.hd (Db.Host.get_host_CPUs ~__context ~self:host) in
  let localflags = Db.Host_cpu.get_flags ~__context ~self:localcpu
  and destflags = Db.Host_cpu.get_flags ~__context ~self:destcpu in
    
    (* XXX : maybe we should just check SVM and VMX flags *)
    if localflags <> destflags then
      warn "Doing migrate between hosts with different cpu flags -- local cpu flags : \"%s\" destination cpu flags : \"%s\"" localflags destflags;

  match vm_r.API.vM_power_state with
  | `Halted | `Suspended ->
      debug "VM is either halted or suspended; resetting affinity only";
      Db.VM.set_affinity ~__context ~self:vm ~value:host
  | `Running ->
      debug "VM is running; attempting migration";
      let live = try bool_of_string (List.assoc "live" options) with _ -> false in
      debug "Sender doing a %s migration" (if live then "live" else "dead");
      let raise_api_error = migration_failure vm localhost host in

      (* We need to connect directly to the receiving host *)
      let hostname = Db.Host.get_address ~__context ~self:host in

      (* Open a cleartext socket to pass to xc_linux_save. We send the session_id in the clear
	 but not any username or password. *)
      let insecure_fd =
	try Unixext.open_connection_fd hostname !Xapi_globs.http_port
	with _ -> raise (Api_errors.Server_error(Api_errors.host_offline, [ Ref.string_of host ])) in
      finally
	(fun () ->      
	   Unixext.set_tcp_nodelay insecure_fd true;

	   let secure_rpc = Helpers.make_rpc ~__context in
	   debug "Sender 1. Logging into remote server";
	   let session_id = Client.Session.slave_login ~rpc:secure_rpc ~host
	     ~psecret:!Xapi_globs.pool_secret in
	   finally
	     (fun () ->
		let path = sprintf "%s?ref=%s"
	          Constants.migrate_uri (Ref.string_of vm) in
		let task_id = Context.get_task_id __context in
		let headers = Xmlrpcclient.connect_headers
		  ~session_id:(Ref.string_of session_id) 
		  ~task_id:(Ref.string_of task_id) hostname path in

		debug "Sender 2. Transmitting an HTTP CONNECT to URI: %s" path;
		let content_length, task_id = 
		  try
		    Xmlrpcclient.http_rpc_fd insecure_fd headers "" 
		  with e ->
		    debug "Caught HTTP-level exception: %s" (ExnHelper.string_of_exn e);
		    begin match Db.Task.get_error_info ~__context ~self:task_id with
		    | [] -> 
			debug "No information in the task object";
			raise e
		    | code :: params ->
			debug "Task object contains error: %s [ %s ]" code (String.concat "; " params);
			raise (Api_errors.Server_error(code, params))
		    end in
		(* At this point we must have received an HTTP 200 OK from the remote. *)

		try
		  (* Transfer the memory image *)
		  with_xal
		    (fun xal ->
		       with_xc_and_xs
			 (fun xc xs ->
			    transmitter ~xal ~__context localhost_migration insecure_fd (vm_migrate_failed vm localhost host) 
			      host session_id vm xc xs live));
		with e ->
		  debug "Sender Caught exception: %s" (ExnHelper.string_of_exn e);
		  debug "Sender Relocking VBDs";
		  (* NB the domain might now be in a crashed state: rely on the event thread
		     to do the cleanup asynchronously. *)
		  raise_api_error e
	     ) (fun () -> 
		  debug "Sender 8.Logging out of remote server";
		  Client.Session.logout ~rpc:secure_rpc ~session_id
	       )
	) (fun () -> 
	     debug "Sender 9. Closing memory image transfer socket";
	     Unix.close insecure_fd)

  | _ ->
      let msg = "Illegal power state in migrate: should have been prevented by allowed_operations" in
      error "%s" msg;
      raise (Api_errors.Server_error(Api_errors.internal_error, [ msg ]))

(* CA-24232: unfortunately the paused/unpaused states of VBDs are not represented in the API so we cannot
   block the migrate request in the master's message forwarding layer. We have to block the request here until
   all the VBDs have been unpaused. Note since VBD.unpause does not acquire the VM lock we can hold onto it here. *)
let with_no_vbds_paused ~__context ~vm f =
  Locking_helpers.with_lock vm
    (fun token () ->
       let interval = 5. in (* every 2 seconds *)
       let nattempts = 5 in (* max 5 attempts *)
       let finished = ref false in
       let attempt = ref 0 in
       while not !finished do
	 incr attempt;
	 (* Only proceed if no VBDs are paused *)
	 let vbds = Db.VM.get_VBDs ~__context ~self:vm in
	 let vbds = List.filter (fun self -> Db.VBD.get_currently_attached ~__context ~self) vbds in       
	 (* Skip empty VBDs *)
	 let vbds = List.filter (fun self -> not(Db.VBD.get_empty ~__context ~self)) vbds in
	 let devices = List.map (fun self -> Xen_helpers.device_of_vbd ~__context ~self) vbds in
	 let paused = with_xs (fun xs -> List.map (fun device -> Device.Vbd.is_paused xs device) devices) in
	 if List.fold_left (||) false paused then begin
	   if !attempt >= nattempts then begin
	     error "Migrate still blocked by a paused VBD after %d attempts (interval %.1f seconds): returning error" nattempts interval;
	     (* Find one VBD which was paused *)
	     let first = fst (List.find (fun (vbd, paused) -> paused) (List.combine vbds paused)) in
	     raise (Api_errors.Server_error(Api_errors.other_operation_in_progress, [ "VBD"; Ref.string_of first ]));
	   end else begin
	     error "Blocking migrate because at least one VBD is paused. Will retry again in %.1f seconds (%d attempts remaining)" 
	       interval (nattempts - !attempt);
	     Thread.delay interval
	   end
	 end else begin
	   f token ();
	   finished := true
	 end
       done
    )
	 
let pool_migrate ~__context ~vm ~host ~options =
	Local_work_queue.wait_in_line Local_work_queue.long_running_queue 
	  (Printf.sprintf "VM.pool_migrate %s" (Context.string_of_task __context))
	  (fun () ->

	     
  with_no_vbds_paused ~__context ~vm
    (fun token () ->

      (* MTC: Initialize the migration event notification system.  If it raises an
         exception, then let it be handled by our caller. *)
      Mtc.event_notify_init ~__context ~vm;

      (* Sometimes, a req to abort is made as soon as the command issued. *)
      if Mtc.event_check_for_abort_req ~__context ~self:vm then begin
        debug "abort detected early";
        let localhost = Helpers.get_localhost ~__context in
        vm_migrate_failed vm localhost host "An external abort event was detected before we could even start migration."
      end;

      (* MTC: Provide a quick indication that we have started *)
      Mtc.event_notify_task_status ~__context ~vm ~status:`pending 0.1;

      (* MTC: Try to migrate and it if it faults, then trap it so we can generate
         an event notification and update our task info. *)
      (try
         (* Invoke migrate hook *)
         Xapi_hooks.vm_pre_migrate ~__context ~reason:Xapi_hooks.reason__migrate_source ~vm;
         pool_migrate_nolock ~__context ~vm ~host ~options;

         (* Provide a quick indication that the task completed successfully *)
         Mtc.event_notify_task_status ~__context ~vm ~status:`success 1.;
      with
        | Api_errors.Server_error (a,b) as e ->
            (if a=Api_errors.task_cancelled
             then Mtc.event_notify_task_status ~__context ~vm ~status:`cancelled 1.
             else Mtc.event_notify_task_status ~__context ~vm ~status:`failure ~str:(ExnHelper.string_of_exn e) 1. );
            raise e
        | e ->
            debug "MTC: exception_handler: Got exception %s" (ExnHelper.string_of_exn e);
            Mtc.event_notify_task_status ~__context ~vm ~status:`failure ~str:(ExnHelper.string_of_exn e) 1. ;
            raise e)
    ) ()
	  )

exception Failure

(** HTTP handler to receive the live memory image *)
let handler req fd =
  let safe_lookup key list =
    if not (List.mem_assoc key list) then begin
	error "Failed to find key %s (list was [ %s ])"
	      key (String.concat "; " (List.map (fun (k, v) -> k ^ ", " ^ v) list));
	Http_svr.headers fd Http.http_403_forbidden;
	raise Failure
    end else List.assoc key list in

  (* Once the memory has been transferred we send back a single byte response
     code indicating whether we received it and restored the domain ok *)

  (* find all the required references *)
  let session_id = Ref.of_string (safe_lookup "session_id" req.Http.cookie) in
  let task_id = Ref.of_string (safe_lookup "task_id" req.Http.cookie) in
  let vm = Ref.of_string (safe_lookup "ref" req.Http.query) in

  Server_helpers.exec_with_forwarded_task ~session_id task_id ~origin:(Context.Http(req,fd)) (fun __context ->
       let localhost = Helpers.get_localhost ~__context in

       (* MTC: If this is a protected VM, then return the peer VM configuration
        * for instantiation (the destination VM where we'll migrate to).  
        * Otherwise, it returns the current VM (which is the unmodified XAPI
        * behavior).  Note that 'dest_vm' is supposed to be identical to 'vm'
        * if the MTC protection code is not enabled.
       *)
       let dest_vm = Mtc.get_peer_vm_or_self ~__context ~self:vm in
       (* We must make sure the VM object is locked locally to exclude races with the 
	  event thread. The sender will have already locked the VM on the remote machine; 
	  we must lock it on the local one. In the case of localhost migration, rely on
	  the sender's lock. *)
       (* Receiver knows the migration is local if "the VM is currently resident on me" *)
       (* MTC: Adhere to the warning above and let's lock the destination VM, which in
        * MTC's case, may be a different VM all together so we can't count on the source
        * to have locked the correct VM. Therefore, we've changed the code below to
        * use a lock on the dest_vm.
        *)
       let localhost_migration = Db.VM.get_resident_on ~__context ~self:dest_vm = localhost in
       let with_locks f = 
	 if localhost_migration && (vm = dest_vm) then f () (* nothing *)
	 else Locking_helpers.with_lock dest_vm (fun token () -> f ()) () in
       debug "Receiver 1. locking VM (if not localhost migration)";
       try
	 with_locks
	   (fun () ->
	      debug "Receiver 2. checking we have enough free memory";
	      with_xc_and_xs
		(fun xc xs ->
			(* XXX: on early failure consider calling TaskHelper.failed? *)
			let memory_required_kib = Memory.kib_of_bytes_used
                         (Memory_check.vm_compute_migrate_memory __context vm) in

(*
			Vmops.with_enough_memory ~__context ~xc ~xs ~memory_required_kib
			(fun () ->
*)
				debug "Receiver 3. sending back HTTP 200 OK";
				Http_svr.headers fd (Http.http_200_ok ());
				receiver ~__context ~localhost localhost_migration fd vm xc xs memory_required_kib
(*
			)
*)
		)
	   )
       with 
	 (* Use the task_id to communicate a more interesting error back *)
       | Api_errors.Server_error(code, params) ->
	   TaskHelper.failed ~__context(code, params)
       | e ->
	   TaskHelper.failed ~__context (Api_errors.internal_error, [ ExnHelper.string_of_exn e ])
    )

(** We don't support cross-pool migration atm *)
let migrate  ~__context ~vm ~dest ~live ~options =
	raise (Api_errors.Server_error(Api_errors.not_implemented, [ "VM.migrate" ]))

