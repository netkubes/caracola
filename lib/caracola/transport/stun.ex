defmodule Caracola.Transport.Stun do
  @moduledoc false
  # Minimal STUN (RFC 5389) for SIP outbound keepalives over UDP (RFC 5626
  # §4.4.2): Binding requests and success responses with an
  # XOR-MAPPED-ADDRESS. UDP listeners answer Binding requests on the SIP
  # port; responses go to the process waiting for their transaction.

  import Bitwise

  @magic 0x2112A442
  @binding_request 0x0001
  @binding_response 0x0101
  @xor_mapped_address 0x0020

  @doc "Returns `true` if a datagram looks like a STUN message."
  @spec stun?(binary()) :: boolean()
  def stun?(<<0::2, _type::14, len::16, @magic::32, _tid::binary-12, _::binary-size(len)>>),
    do: true

  def stun?(_data), do: false

  @doc "A Binding request and its transaction id."
  @spec request() :: {binary(), binary()}
  def request do
    tid = :crypto.strong_rand_bytes(12)
    {tid, <<@binding_request::16, 0::16, @magic::32, tid::binary>>}
  end

  @doc "The success response to a Binding request from `ip` and `port`."
  @spec response(binary(), :inet.ip_address(), :inet.port_number()) :: binary()
  def response(tid, ip, port) do
    xport = bxor(port, @magic >>> 16)

    value =
      case ip do
        {a, b, c, d} ->
          <<addr::32>> = <<a, b, c, d>>
          <<0, 1, xport::16, bxor(addr, @magic)::32>>

        {_, _, _, _, _, _, _, _} ->
          <<addr::128>> = for(n <- Tuple.to_list(ip), into: <<>>, do: <<n::16>>)
          <<mask::128>> = <<@magic::32, tid::binary>>
          <<0, 2, xport::16, bxor(addr, mask)::128>>
      end

    attr = <<@xor_mapped_address::16, byte_size(value)::16, value::binary>>
    <<@binding_response::16, byte_size(attr)::16, @magic::32, tid::binary, attr::binary>>
  end

  @doc "Decodes a STUN message."
  @spec decode(binary()) ::
          {:request, binary()}
          | {:response, binary(), {:inet.ip_address(), :inet.port_number()} | nil}
          | :error
  def decode(<<@binding_request::16, _len::16, @magic::32, tid::binary-12, _::binary>>),
    do: {:request, tid}

  def decode(
        <<@binding_response::16, len::16, @magic::32, tid::binary-12, attrs::binary-size(len)>>
      ),
      do: {:response, tid, mapped(attrs, tid)}

  def decode(_data), do: :error

  defp mapped(<<@xor_mapped_address::16, len::16, value::binary-size(len), _::binary>>, tid) do
    case value do
      <<_, 1, xport::16, xaddr::32>> ->
        <<a, b, c, d>> = <<bxor(xaddr, @magic)::32>>
        {{a, b, c, d}, bxor(xport, @magic >>> 16)}

      <<_, 2, xport::16, xaddr::128>> ->
        <<mask::128>> = <<@magic::32, tid::binary>>
        ip = for <<(n::16 <- <<bxor(xaddr, mask)::128>>)>>, do: n
        {List.to_tuple(ip), bxor(xport, @magic >>> 16)}

      _ ->
        nil
    end
  end

  # Other attributes (padded to 4 bytes)
  defp mapped(<<_type::16, len::16, rest::binary>>, tid) do
    skip = len + rem(4 - rem(len, 4), 4)

    case rest do
      <<_::binary-size(^skip), rest::binary>> -> mapped(rest, tid)
      _ -> nil
    end
  end

  defp mapped(_attrs, _tid), do: nil
end
