(*
 * Copyright (C) 2011-2013 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Common
open Cmdliner
open Lwt

module Impl = Vhd.Make(Vhd_lwt)
open Impl
open Vhd
open Vhd_lwt

let require name arg = match arg with
  | None -> failwith (Printf.sprintf "Please supply a %s argument" name)
  | Some x -> x

let get common filename key =
  try
    let filename = require "filename" filename in
    let key = require "key" key in
    let t =
      Vhd_IO.openfile ~path:common.path filename >>= fun t ->
      let result = Vhd.Field.get t key in
      Vhd_IO.close t >>= fun () ->
      return result in
    match Lwt_main.run t with
    | Some v ->
      Printf.printf "%s\n" v;
      `Ok ()
    | None -> raise Not_found
  with
    | Failure x ->
      `Error(true, x)
    | Not_found ->
      `Error(true, Printf.sprintf "Unknown key. Known keys are: %s" (String.concat ", " Vhd.Field.list))

let info common filename =
  try
    let filename = require "filename" filename in
    let t =
      Vhd_IO.openfile ~path:common.path filename >>= fun t ->
      let all = List.map (fun f ->
        match Vhd.Field.get t f with
        | Some v -> [ f; v ]
        | None -> assert false
      ) Vhd.Field.list in
      print_table ["field"; "value"] all;
      return () in
    Lwt_main.run t;
    `Ok ()
  with Failure x ->
    `Error(true, x)

let create common filename size parent =
  try
    begin let filename = require "filename" filename in
    match parent, size with
    | None, None -> failwith "Please supply either a size or a parent"
    | None, Some size ->
      let size = parse_size size in
      let t =
        Vhd_IO.create_dynamic ~filename ~size () >>= fun vhd ->
        Vhd_IO.close vhd in
      Lwt_main.run t
    | Some parent, None ->
      let t =
        Vhd_IO.openfile ~path:common.path parent >>= fun parent ->
        Vhd_IO.create_difference ~filename ~parent () >>= fun vhd ->
        Vhd_IO.close parent >>= fun () ->
        Vhd_IO.close vhd >>= fun () ->
        return () in
      Lwt_main.run t
    | Some parent, Some size ->
      failwith "Overriding the size in a child node not currently implemented"
    end;
     `Ok ()
  with Failure x ->
    `Error(true, x)

let check common filename =
  try
    let filename = require "filename" filename in
    let t =
      Vhd_IO.openfile ~path:common.path filename >>= fun vhd ->
      Vhd.check_overlapping_blocks vhd;
      return () in
    Lwt_main.run t;
    `Ok ()
  with Failure x ->
    `Error(true, x)

module P = Progress_bar(Int64)

let console_progress_bar total_work =
  let p = P.create 80 0L total_work in
  fun work_done ->
    let progress_updated = P.update p work_done in
    if progress_updated then P.print_bar p;
    if work_done = total_work then Printf.printf "\n%!"

let no_progress_bar _ _ = ()

let stream_human common _ s _ _ ?(progress = no_progress_bar) () =
  (* How much space will we need for the sector numbers? *)
  let sectors = Int64.(shift_right (add s.size.total 511L) sector_shift) in
  let decimal_digits = int_of_float (ceil (log10 (Int64.to_float sectors))) in
  Printf.printf "# stream summary:\n";
  Printf.printf "# size of the final artifact: %Ld\n" s.size.total;
  Printf.printf "# size of metadata blocks:    %Ld\n" s.size.metadata;
  Printf.printf "# size of empty space:        %Ld\n" s.size.empty;
  Printf.printf "# size of referenced blocks:  %Ld\n" s.size.copy;
  Printf.printf "# offset : contents\n";
  fold_left (fun sector x ->
    Printf.printf "%s: %s\n"
      (padto ' ' decimal_digits (Int64.to_string sector))
      (Element.to_string x);
    return (Int64.add sector (Element.len x))
  ) 0L s.elements >>= fun _ ->
  Printf.printf "# end of stream\n";
  return None

let stream_nbd common c s prezeroed _ ?(progress = no_progress_bar) () =
  let c = { Nbd_lwt_client.read = c.Channels.really_read; write = c.Channels.really_write } in

  Nbd_lwt_client.negotiate c >>= fun (server, size, flags) ->
  (* Work to do is: non-zero data to write + empty sectors if the
     target is not prezeroed *)
  let total_work = Int64.(add (add s.size.metadata s.size.copy) (if prezeroed then 0L else s.size.empty)) in
  let p = progress total_work in

  ( if not prezeroed then expand_empty s else return s ) >>= fun s ->
  expand_copy s >>= fun s ->

  fold_left (fun (sector, work_done) x ->
    ( match x with
      | Element.Sectors data ->
        Nbd_lwt_client.write server data (Int64.mul sector 512L) >>= fun () ->
        return Int64.(of_int (Cstruct.len data))
      | Element.Empty n -> (* must be prezeroed *)
        assert prezeroed;
        return 0L
      | _ -> fail (Failure (Printf.sprintf "unexpected stream element: %s" (Element.to_string x))) ) >>= fun work ->
    let sector = Int64.add sector (Element.len x) in
    let work_done = Int64.add work_done work in
    p work_done;
    return (sector, work_done)
  ) (0L, 0L) s.elements >>= fun _ ->
  p total_work;

  return (Some total_work)

let stream_chunked common c s prezeroed _ ?(progress = no_progress_bar) () =
  (* Work to do is: non-zero data to write + empty sectors if the
     target is not prezeroed *)
  let total_work = Int64.(add (add s.size.metadata s.size.copy) (if prezeroed then 0L else s.size.empty)) in
  let p = progress total_work in

  ( if not prezeroed then expand_empty s else return s ) >>= fun s ->
  expand_copy s >>= fun s ->

  let header = Cstruct.create Chunked.sizeof in
  fold_left (fun(sector, work_done) x ->
    ( match x with
      | Element.Sectors data ->
        let t = { Chunked.offset = Int64.(mul sector 512L); data } in
        Chunked.marshal header t;
        c.Channels.really_write header >>= fun () ->
        c.Channels.really_write data >>= fun () ->
        return Int64.(of_int (Cstruct.len data))
      | Element.Empty n -> (* must be prezeroed *)
        assert prezeroed;
        return 0L
      | _ -> fail (Failure (Printf.sprintf "unexpected stream element: %s" (Element.to_string x))) ) >>= fun work ->
    let sector = Int64.add sector (Element.len x) in
    let work_done = Int64.add work_done work in
    p work_done;
    return (sector, work_done)
  ) (0L, 0L) s.elements >>= fun _ ->
  p total_work;

  (* Send the end-of-stream marker *)
  Chunked.marshal header { Chunked.offset = 0L; data = Cstruct.create 0 };
  c.Channels.really_write header >>= fun () ->

  return (Some total_work)

let stream_raw common c s prezeroed _ ?(progress = no_progress_bar) () =
  (* Work to do is: non-zero data to write + empty sectors if the
     target is not prezeroed *)
  let total_work = Int64.(add (add s.size.metadata s.size.copy) (if prezeroed then 0L else s.size.empty)) in
  let p = progress total_work in

  ( if not prezeroed then expand_empty s else return s ) >>= fun s ->
  expand_copy s >>= fun s ->

  fold_left (fun work_done x ->
    (match x with
      | Element.Sectors data ->
        c.Channels.really_write data >>= fun () ->
        return Int64.(of_int (Cstruct.len data))
      | Element.Empty n -> (* must be prezeroed *)
        c.Channels.skip (Int64.(mul n 512L)) >>= fun () ->
        assert prezeroed;
        return 0L
      | _ -> fail (Failure (Printf.sprintf "unexpected stream element: %s" (Element.to_string x))) ) >>= fun work ->
    let work_done = Int64.add work_done work in
    p work_done;
    return work_done
  ) 0L s.elements >>= fun _ ->
  p total_work;

  return (Some total_work)

module TarStream = struct
  type t = {
    work_done: int64;
    total_size: int64;
    ctx: Sha1.ctx;
    nr_bytes_remaining: int; (* start at 0 *)
    next_counter: int;
    mutable header: Tar.Header.t option;
  }

  let to_string t =
    Printf.sprintf "work_done = %Ld; nr_bytes_remaining = %d; next_counter = %d; filename = %s"
      t.work_done t.nr_bytes_remaining t.next_counter
      (match t.header with None -> "None" | Some h -> h.Tar.Header.file_name)

  let initial total_size = {
    work_done = 0L; ctx = Sha1.init (); nr_bytes_remaining = 0;
    next_counter = 0; header = None; total_size
  }

  let sha1_update_cstruct ctx buffer =
    let ofs = buffer.Cstruct.off in
    let len = buffer.Cstruct.len in
    let buf = buffer.Cstruct.buffer in
    let buffer' : (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t = Bigarray.Array1.sub buf ofs len in
    (* XXX: need a better way to do this *)
    let buffer'': (int,  Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t = Obj.magic buffer' in
    Sha1.update_buffer ctx buffer''

  let make_tar_header prefix counter suffix file_size =
    Tar.Header.({
      file_name = Printf.sprintf "%s%08d%s" prefix counter suffix;
      file_mode = 0o644;
      user_id = 0;
      group_id = 0;
      file_size = Int64.of_int file_size;
      mod_time = Int64.of_float (Unix.gettimeofday ());
      link_indicator = Tar.Header.Link.Normal;
      link_name = ""
    })      
end

let stream_tar common c s _ prefix ?(progress = no_progress_bar) () =
  let open TarStream in
  let block_size = 1024 * 1024 in
  let header = Memory.alloc Tar.Header.length in
  let zeroes = Memory.alloc block_size in
  for i = 0 to Cstruct.len zeroes - 1 do
    Cstruct.set_uint8 zeroes i 0
  done;
  (* This undercounts by missing the tar headers and occasional empty sector *)
  let total_work = Int64.(add s.size.metadata s.size.copy) in
  let p = progress total_work in

  expand_copy s >>= fun s ->

  (* Write [data] to the tar-format stream currnetly in [state] *)
  let rec input state data =
    (* Write as much as we can into the current file *)
    let len = Cstruct.len data in
    let this_block_len = min len state.nr_bytes_remaining in
    let this_block = Cstruct.sub data 0 this_block_len in
    sha1_update_cstruct state.ctx this_block;
    c.Channels.really_write this_block >>= fun () ->
    let nr_bytes_remaining = state.nr_bytes_remaining - this_block_len in
    let state = { state with nr_bytes_remaining } in
    let rest = Cstruct.shift data this_block_len in
    (* If we've hit the end of a block then output the hash *)
    ( if nr_bytes_remaining = 0 then match state.header with
      | Some hdr ->
        c.Channels.really_write (Tar.Header.zero_padding hdr) >>= fun () ->
        let hash = Sha1.(to_hex (finalize state.ctx)) in
        let ctx = Sha1.init () in
        let hdr' = { hdr with
          Tar.Header.file_name = hdr.Tar.Header.file_name ^ ".checksum";
          file_size = Int64.of_int (String.length hash)
        } in
        Tar.Header.marshal header hdr';
        c.Channels.really_write header >>= fun () ->
        Cstruct.blit_from_string hash 0 header 0 (String.length hash);
        c.Channels.really_write (Cstruct.sub header 0 (String.length hash)) >>= fun () ->
        c.Channels.really_write (Tar.Header.zero_padding hdr') >>= fun () ->
        return { state with ctx; header = None }
      | None ->
        return state
      else return state ) >>= fun state ->

    (* If we have unwritten data then output the next header *)
    ( if nr_bytes_remaining = 0 && Cstruct.len rest > 0 then begin
        (* XXX the last block might be smaller than block_size *)
        let hdr = make_tar_header prefix state.next_counter "" block_size in
        Tar.Header.marshal header hdr;
        c.Channels.really_write header >>= fun () ->
        return { state with nr_bytes_remaining = block_size;
                 next_counter = state.next_counter + 1;
                 header = Some hdr }
      end else return { state with nr_bytes_remaining } ) >>= fun state ->

    if Cstruct.len rest > 0
    then input state rest
    else return state in

  let rec empty state bytes =
    let write state bytes =
      let this = Int64.(to_int (min bytes (of_int (Cstruct.len zeroes)))) in
      input state (Cstruct.sub zeroes 0 this) >>= fun state ->
      empty state Int64.(sub bytes (of_int this)) in
    if bytes = 0L
    then return state
    (* If we're in the middle of a block, then complete it *)
    else if 0 < state.nr_bytes_remaining && state.nr_bytes_remaining < block_size
    then begin
      let this = min (Int64.of_int state.nr_bytes_remaining) bytes in
      write state this >>= fun state ->
      empty state (Int64.sub bytes this)
    (* If we're the first or last block then always include *)
    end else if state.work_done = 0L || Int64.(sub state.total_size state.work_done <= (of_int block_size))
    then write state bytes
    else if bytes >= (Int64.of_int block_size) then begin
      (* If n > block_size (in sectors) then we can omit empty blocks *)
      empty { state with next_counter = state.next_counter + 1 } Int64.(sub bytes (of_int block_size))
    end else write state bytes in

  fold_left (fun state x ->
    (match x with
      | Element.Sectors data ->
        input state data
      | Element.Empty n ->
        empty state (Int64.(mul n 512L))
      | _ -> fail (Failure (Printf.sprintf "unexpected stream element: %s" (Element.to_string x))) ) >>= fun state ->
    let work = Int64.mul (Element.len x) 512L in
    let work_done = Int64.add state.work_done work in
    p work_done;
    return { state with work_done }
  ) (initial s.size.total) s.elements >>= fun _ ->
  p total_work;

  return (Some total_work)

module TarInput = struct
  type t = {
    ctx: Sha1.ctx;
  }
  let initial () = { ctx = Sha1.init () }
end

let serve_tar_to_raw ?expected_prefix total_size c dest =
  let module M = Tar.Archive(Lwt) in
  let twomib = 2 * 1024 * 1024 in
  let buffer = Memory.alloc twomib in
  let header = Memory.alloc 512 in

  let rec loop () =
    c.Channels.really_read header >>= fun () ->
    match Tar.Header.unmarshal header with
    | None -> fail (Failure "failed to unmarshal header")
    | Some hdr ->
      ( match expected_prefix with
        | None -> return ()
        | Some p ->
          if not(startswith p hdr.Tar.Header.file_name)
          then fail (Failure (Printf.sprintf "expected filename prefix %s, got %s" p hdr.Tar.Header.file_name))
          else return () ) >>= fun () ->
      (* either 'counter' or 'counter.checksum' *)

  loop 0

  fold (fun 

  ) (TarInput.initial ()) 
    (fun x -> Lwt_stream.next (blkif#read_512 x 1L))

  let header = Cstruct.create Chunked.sizeof in
  let twomib = 2 * 1024 * 1024 in
  let buffer = Memory.alloc twomib in
  let rec loop () =
    c.Channels.really_read header >>= fun () ->
    if Chunked.is_last_chunk header then begin
      Printf.fprintf stderr "Received last chunk.\n%!";
      return ()
    end else begin
      let rec block offset remaining =
        let this = Int32.(to_int (min (of_int twomib) remaining)) in
        let buf = if this < twomib then Cstruct.sub buffer 0 this else buffer in
        c.Channels.really_read buf >>= fun () ->
        Fd.really_write dest offset buf >>= fun () ->
        let offset = Int64.(add offset (of_int this)) in
        let remaining = Int32.(sub remaining (of_int this)) in
        if remaining > 0l
        then block offset remaining
        else return () in
      block (Chunked.get_offset header) (Chunked.get_len header) >>= fun () ->
      loop ()
    end in
  loop ()


open StreamCommon

type endpoint =
  | Stdout
  | Null
  | File_descr of Lwt_unix.file_descr
  | Sockaddr of Lwt_unix.sockaddr
  | File of string
  | Http of Uri.t
  | Https of Uri.t

let endpoint_of_string = function
  | "stdout:" -> return Stdout
  | "null:" -> return Null
  | uri ->
    let uri' = Uri.of_string uri in
    begin match Uri.scheme uri' with
    | Some "fd" ->
      return (File_descr (Uri.path uri' |> int_of_string |> file_descr_of_int |> Lwt_unix.of_unix_file_descr))
    | Some "tcp" ->
      let host = match Uri.host uri' with None -> failwith "Please supply a host in the URI" | Some host -> host in
      let port = match Uri.port uri' with None -> failwith "Please supply a port in the URI" | Some port -> port in
      Lwt_unix.gethostbyname host >>= fun host_entry ->
      return (Sockaddr(Lwt_unix.ADDR_INET(host_entry.Lwt_unix.h_addr_list.(0), port)))
    | Some "unix" ->
      return (Sockaddr(Lwt_unix.ADDR_UNIX(Uri.path uri')))
    | Some "file" ->
      return (File(Uri.path uri'))
    | Some "http" ->
      return (Http uri')
    | Some "https" ->
      return (Https uri')
    | Some x ->
      fail (Failure (Printf.sprintf "Unknown URI scheme: %s" x))
    | None ->
      fail (Failure (Printf.sprintf "Failed to parse URI: %s" uri))
    end

let socket sockaddr =
  let family = match sockaddr with
  | Lwt_unix.ADDR_INET(_, _) -> Unix.PF_INET
  | Lwt_unix.ADDR_UNIX _ -> Unix.PF_UNIX in
  Lwt_unix.socket family Unix.SOCK_STREAM 0

let colon = Re_str.regexp_string ":"

let make_stream common source relative_to source_format destination_format =
  match source_format, destination_format with
  | "hybrid", "raw" ->
    (* expect source to be block_device:vhd *)
    begin match Re_str.bounded_split colon source 2 with
    | [ raw; vhd ] ->
      Vhd_IO.openfile ~path:common.path vhd >>= fun t ->
      Vhd_lwt.Fd.openfile raw >>= fun raw ->
      ( match relative_to with None -> return None | Some f -> Vhd_IO.openfile ~path:common.path f >>= fun t -> return (Some t) ) >>= fun from ->
      Vhd_input.hybrid ?from raw t
    | _ ->
      fail (Failure (Printf.sprintf "Failed to parse hybrid source: %s (expected raw_disk|vhd_disk)" source))
    end
  | "vhd", "vhd" ->
    Vhd_IO.openfile ~path:common.path source >>= fun t ->
    ( match relative_to with None -> return None | Some f -> Vhd_IO.openfile ~path:common.path f >>= fun t -> return (Some t) ) >>= fun from ->
    Vhd_input.vhd ?from t
  | "vhd", "raw" ->
    Vhd_IO.openfile ~path:common.path source >>= fun t ->
    ( match relative_to with None -> return None | Some f -> Vhd_IO.openfile ~path:common.path f >>= fun t -> return (Some t) ) >>= fun from ->
    Vhd_input.raw ?from t
  | "raw", "vhd" ->
    Raw_IO.openfile source >>= fun t ->
    Raw_input.vhd t
  | "raw", "raw" ->
    Raw_IO.openfile source >>= fun t ->
    Raw_input.raw t
  | _, _ -> assert false

let write_stream common s destination source_protocol destination_protocol prezeroed progress tar_filename_prefix = 
  endpoint_of_string destination >>= fun endpoint ->
  let use_ssl = match endpoint with Https _ -> true | _ -> false in
  ( match endpoint with
    | File path ->
      Lwt_unix.openfile path [ Unix.O_RDWR ] 0o0 >>= fun fd ->
      Channels.of_seekable_fd fd >>= fun c ->
      return (c, [ NoProtocol; Human; Tar ])
    | Null ->
      Lwt_unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o0 >>= fun fd ->
      Channels.of_raw_fd fd >>= fun c ->
      return (c, [ NoProtocol; Human; Tar ])
    | Stdout ->
      Channels.of_raw_fd Lwt_unix.stdout >>= fun c ->
      return (c, [ NoProtocol; Human; Tar ])
    | File_descr fd ->
      Channels.of_raw_fd fd >>= fun c ->
      return (c, [ Nbd; NoProtocol; Chunked; Human; Tar ])
    | Sockaddr sockaddr ->
      let sock = socket sockaddr in
      Lwt_unix.connect sock sockaddr >>= fun () ->
      Channels.of_raw_fd sock >>= fun c ->
      return (c, [ Nbd; NoProtocol; Chunked; Human; Tar ])
    | Https uri'
    | Http uri' ->
      (* TODO: https is not currently implemented *)
      let port = match Uri.port uri' with None -> (if use_ssl then 443 else 80) | Some port -> port in
      let host = match Uri.host uri' with None -> failwith "Please supply a host in the URI" | Some host -> host in
      Lwt_unix.gethostbyname host >>= fun host_entry ->
      let sockaddr = Lwt_unix.ADDR_INET(host_entry.Lwt_unix.h_addr_list.(0), port) in
      let sock = socket sockaddr in
      Lwt_unix.connect sock sockaddr >>= fun () ->

      let open Cohttp in
      ( if use_ssl then Channels.of_ssl_fd sock else Channels.of_raw_fd sock ) >>= fun c ->
  
      let module Request = Request.Make(Cohttp_unbuffered_io) in
      let module Response = Response.Make(Cohttp_unbuffered_io) in
      let headers = Header.init () in
      let k, v = Cookie.Cookie_hdr.serialize [ "chunked", "true" ] in
      let headers = Header.add headers k v in
      let headers = match Uri.userinfo uri' with
        | None -> headers
        | Some x ->
          begin match Re_str.bounded_split_delim (Re_str.regexp_string ":") x 2 with
          | [ user; pass ] ->
            let b = Cohttp.Auth.(to_string (Basic (user, pass))) in
            Header.add headers "authorization" b
          | _ ->
            Printf.fprintf stderr "I don't know how to handle authentication for this URI.\n Try scheme://user:password@host/path\n";
            exit 1
          end in
      let request = Cohttp.Request.make ~meth:`PUT ~version:`HTTP_1_1 ~headers uri' in
      Request.write (fun t _ -> return ()) request c >>= fun () ->
      Response.read (Cohttp_unbuffered_io.make_input c) >>= fun r ->
      begin match r with
      | None -> fail (Failure "Unable to parse HTTP response from server")
      | Some x ->
        let code = Code.code_of_status (Cohttp.Response.status x) in
        if Code.is_success code then begin
          let advertises_nbd =
            let headers = Header.to_list (Cohttp.Response.headers x) in
            let headers = List.map (fun (x, y) -> String.lowercase x, String.lowercase y) headers in
            let te = "transfer-encoding" in
            List.mem_assoc te headers && (List.assoc te headers = "nbd") in
          if advertises_nbd
          then return(c, [ Nbd ])
          else return(c, [ Chunked; NoProtocol ])
        end else fail (Failure (Code.reason_phrase_of_code code))
      end
    ) >>= fun (c, possible_protocols) ->
    let destination_protocol = match destination_protocol with
      | Some x -> x
      | None ->
        let t = List.hd possible_protocols in
        Printf.fprintf stderr "Using protocol: %s\n%!" (string_of_protocol t);
        t in
    if not(List.mem destination_protocol possible_protocols)
    then fail(Failure(Printf.sprintf "this destination only supports protocols: [ %s ]" (String.concat "; " (List.map string_of_protocol possible_protocols))))
    else
      let start = Unix.gettimeofday () in
      (match destination_protocol with
          | Nbd -> stream_nbd
          | Human -> stream_human
          | Chunked -> stream_chunked
          | Tar -> stream_tar
          | NoProtocol -> stream_raw) common c s prezeroed tar_filename_prefix ~progress () >>= fun p ->
      c.Channels.close () >>= fun () ->
      match p with
      | Some p ->
        let time = Unix.gettimeofday () -. start in
        let physical_rate = Int64.(to_float p /. time) in
        if common.Common.verb then begin
          let add_unit x =
            let kib = 1024. in
            let mib = kib *. 1024. in
            let gib = mib *. 1024. in
            let tib = gib *. 1024. in
            if x /. tib > 1. then Printf.sprintf "%.1f TiB" (x /. tib)
            else if x /. gib > 1. then Printf.sprintf "%.1f GiB" (x /. gib)
            else if x /. mib > 1. then Printf.sprintf "%.1f MiB" (x /. mib)
            else if x /. kib > 1. then Printf.sprintf "%.1f KiB" (x /. kib)
            else Printf.sprintf "%.1f B" x in

          Printf.printf "Time taken: %s\n" (hms (int_of_float time));
          Printf.printf "Physical data rate: %s/sec\n" (add_unit physical_rate);
          let speedup = Int64.(to_float s.size.total /. (to_float p)) in
          Printf.printf "Speedup: %.1f\n" speedup;
          Printf.printf "Virtual data rate: %s/sec\n" (add_unit (physical_rate *. speedup));
        end;
        return ()
      | None -> return ()


let stream_t common args ?(progress = no_progress_bar) () =
  make_stream common args.StreamCommon.source args.StreamCommon.relative_to args.StreamCommon.source_format args.StreamCommon.destination_format >>= fun s ->
  write_stream common s args.StreamCommon.destination args.StreamCommon.source_protocol args.StreamCommon.destination_protocol args.StreamCommon.prezeroed progress args.StreamCommon.tar_filename_prefix

let stream common args =
  try
    File.use_unbuffered := common.Common.unbuffered;

    let progress_bar = if args.StreamCommon.progress then console_progress_bar else no_progress_bar in

    let thread = stream_t common args ~progress:progress_bar () in
    Lwt_main.run thread;
    `Ok ()
  with Failure x ->
    `Error(true, x)

lt serve_chunked_to_raw c dest =
  let header = Cstruct.create Chunked.sizeof in
  let twomib = 2 * 1024 * 1024 in
  let buffer = Memory.alloc twomib in
  let rec loop () =
    c.Channels.really_read header >>= fun () ->
    if Chunked.is_last_chunk header then begin
      Printf.fprintf stderr "Received last chunk.\n%!";
      return ()
    end else begin
      let rec block offset remaining =
        let this = Int32.(to_int (min (of_int twomib) remaining)) in
        let buf = if this < twomib then Cstruct.sub buffer 0 this else buffer in
        c.Channels.really_read buf >>= fun () ->
        Fd.really_write dest offset buf >>= fun () ->
        let offset = Int64.(add offset (of_int this)) in
        let remaining = Int32.(sub remaining (of_int this)) in
        if remaining > 0l
        then block offset remaining
        else return () in
      block (Chunked.get_offset header) (Chunked.get_len header) >>= fun () ->
      loop ()
    end in
  loop ()

let serve common_options source source_fd source_protocol destination destination_format =
  try
    File.use_unbuffered := common_options.Common.unbuffered;

    let source_protocol = protocol_of_string (require "source-protocol" source_protocol) in

    let supported_formats = [ "raw" ] in
    if not (List.mem destination_format supported_formats)
    then failwith (Printf.sprintf "%s is not a supported format" destination_format);
    let supported_protocols = [ Chunked; Tar ] in
    if not (List.mem source_protocol supported_protocols)
    then failwith (Printf.sprintf "%s is not a supported source protocol" (string_of_protocol source_protocol));

    let thread =
      endpoint_of_string destination >>= fun destination_endpoint ->
      ( match source_fd with
        | None -> endpoint_of_string source
        | Some fd -> return (File_descr (Lwt_unix.of_unix_file_descr (file_descr_of_int fd))) ) >>= fun source_endpoint ->
      ( match source_endpoint with
        | File_descr fd ->
          Channels.of_raw_fd fd >>= fun c ->
          return c
        | Sockaddr s ->
          let sock = socket s in
          Lwt_unix.bind sock s;
          Lwt_unix.listen sock 1;
          Lwt_unix.accept sock >>= fun (fd, _) ->
          Channels.of_raw_fd fd >>= fun c ->
          return c
        | _ -> failwith (Printf.sprintf "Not implemented: serving from source %s" source) ) >>= fun source_sock ->
      ( match destination_endpoint with
        | File path -> Fd.openfile path
        | _ -> failwith (Printf.sprintf "Not implemented: writing to destination %s" destination) ) >>= fun destination_fd ->
      ( match source_protocol with
        | Chunked -> serve_chunked_to_raw source_sock destination_fd
        | Tar -> serve_tar_to_raw source_sock destination_fd ) >>= fun () ->
      (try Fd.fsync destination_fd; return () with _ -> fail (Failure "fsync failed")) in
    Lwt_main.run thread;
    `Ok ()
  with Failure x ->
  `Error(true, x)
