defmodule Caracola.Dialog.Ref do
  @moduledoc false
  # References to a dialog in headers, as in Replaces (RFC 3891) and Join
  # (RFC 3911): "call-id;to-tag=...;from-tag=...", with the tags as seen
  # by the UA receiving the header.

  alias Caracola.{Dialog, Message, Util}

  # The value for a dialog of this UA, to be sent to its remote party or to
  # a third UA (the tags as seen by the remote party)
  def value(dialog) do
    with {:ok, %Dialog{} = dialog} <- Dialog.get(dialog) do
      local = Util.opt(dialog.local_uri.ext_params, "tag")
      remote = Util.opt(dialog.remote_uri.ext_params, "tag")
      {:ok, "#{dialog.call_id};to-tag=#{remote};from-tag=#{local}"}
    end
  end

  # A Refer-To with the header for a dialog, as "<uri?Name=value>"
  def refer_to(uri, name, dialog) do
    with {:ok, value} <- value(dialog) do
      {:ok, "<#{uri}?#{name}=#{URI.encode(value, &URI.char_unreserved?/1)}>"}
    end
  end

  # The call and dialog id of a header, and its other parameters. The to-tag
  # is ours, so the dialog id is the one of an incoming request with these
  # tags.
  def parse(req, name) do
    with [value] <- Message.header(req, name),
         [call_id | params] <- String.split(value, ";"),
         params = Enum.map(params, &param/1),
         call_id when call_id != "" <- String.trim(call_id),
         {_, to_tag} when is_binary(to_tag) <- List.keyfind(params, "to-tag", 0),
         {_, from_tag} when is_binary(from_tag) <- List.keyfind(params, "from-tag", 0) do
      # As Dialog.id/2 for a request with these tags
      {:ok, call_id, Util.hash({from_tag, to_tag}), params}
    else
      [] -> :none
      _ -> :error
    end
  end

  # The handle of the dialog of a header (nil if it has no valid one)
  def handle(%Message{service: service} = req, name) do
    case parse(req, name) do
      {:ok, call_id, id, _params} -> {:dialog, service, call_id, id}
      _ -> nil
    end
  end

  # A dialog of the service. One of this same call is in the call state
  # (its process is the one running the callback).
  def find(call_id, id, %{call_id: call_id} = call), do: Caracola.Call.Dialog.find(id, call)

  def find(call_id, id, call) do
    case Dialog.get({:dialog, call.service, call_id, id}) do
      {:ok, dialog} -> dialog
      _ -> nil
    end
  end

  defp param(param) do
    case String.split(param, "=", parts: 2) do
      [name, value] -> {Util.ascii_downcase(String.trim(name)), String.trim(value)}
      [name] -> {Util.ascii_downcase(String.trim(name)), nil}
    end
  end
end
