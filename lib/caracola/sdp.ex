defmodule Caracola.SDP do
  @moduledoc """
  RFC 4566 SDP parser and generator. Port of NkSIP's `nksip_sdp`.

  Lines must appear in the order mandated by the RFC. As in NkSIP, `b=`
  lines found among the `a=` lines are accepted (FreeSWITCH sends them).

      iex> {:ok, sdp} = Caracola.SDP.parse("v=0\\r\\no=- 1 2 IN IP4 h\\r\\ns=-\\r\\nt=0 0\\r\\nm=audio 4000 RTP/AVP 0\\r\\na=sendrecv\\r\\n")
      iex> [media] = sdp.medias
      iex> {media.media, media.port, media.fmt, media.attributes}
      {"audio", 4000, ["0"], [{"sendrecv", []}]}
  """

  alias Caracola.SDP.Media

  @typedoc "A connection address: network type, address type and address."
  @type address :: {type :: String.t(), addr_type :: String.t(), addr :: String.t()}
  @typedoc "An attribute: its name and values."
  @type attribute :: {name :: String.t(), values :: [String.t()]}
  @typedoc "A time description: start, stop and repeats."
  @type time :: {start :: non_neg_integer(), stop :: non_neg_integer(), reps :: [String.t()]}
  @typedoc "The direction of a media stream."
  @type media_status :: :inactive | :recvonly | :sendonly | :sendrecv

  @typedoc "A media description to build a session with `Caracola.SDP.new/2`: media type, port and codecs or attributes."
  @type media_spec ::
          {media :: String.t(), port :: :inet.port_number(),
           [{:rtpmap, non_neg_integer(), String.t()} | String.t() | atom()]}

  @typedoc "A session description (RFC 8866)."
  @type t :: %__MODULE__{
          sdp_vsn: String.t(),
          user: String.t(),
          id: non_neg_integer(),
          vsn: non_neg_integer(),
          address: address(),
          session: String.t(),
          info: String.t() | nil,
          uri: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          connect: address() | nil,
          bandwidth: [String.t()],
          time: [time()],
          zone: String.t() | nil,
          key: String.t() | nil,
          attributes: [attribute()],
          medias: [Media.t()]
        }

  defstruct sdp_vsn: "0",
            user: "-",
            id: 0,
            vsn: 0,
            address: {"IN", "IP4", "0.0.0.0"},
            session: "-",
            info: nil,
            uri: nil,
            email: nil,
            phone: nil,
            connect: nil,
            bandwidth: [],
            time: [],
            zone: nil,
            key: nil,
            attributes: [],
            medias: []

  @statuses ~w(inactive recvonly sendonly sendrecv)

  ## ===================================================================
  ## Building
  ## ===================================================================

  @doc """
  Builds a basic SDP for `host` with one `m=` section per media spec.

  Each spec is `{media, port, attributes}`, where an attribute is either
  `{:rtpmap, payload, data}` (which also adds the payload to the format list)
  or a raw attribute like `"ptime:20"` or `:sendrecv`. The protocol is
  `RTP/AVP`.

      iex> sdp = Caracola.SDP.new("10.0.0.1", [{"audio", 4000, [{:rtpmap, 0, "PCMU/8000"}, :sendrecv]}])
      iex> {sdp.connect, hd(sdp.medias).fmt, hd(sdp.medias).attributes}
      {{"IN", "IP4", "10.0.0.1"}, ["0"], [{"rtpmap", ["0", "PCMU/8000"]}, {"sendrecv", []}]}
  """
  @spec new(String.t(), [media_spec()]) :: t()
  def new(host, medias \\ []) do
    now = System.os_time(:second)
    address = {"IN", addr_type(host), host}

    %__MODULE__{
      id: now,
      vsn: now,
      address: address,
      connect: address,
      time: [{0, 0, []}],
      medias: Enum.map(medias, &new_media/1)
    }
  end

  defp new_media({media, port, attrs}) do
    %Media{
      media: to_string(media),
      port: port,
      fmt: for({:rtpmap, pos, _} <- attrs, do: to_string(pos)),
      attributes:
        Enum.map(attrs, fn
          {:rtpmap, pos, data} -> {"rtpmap", [to_string(pos), to_string(data)]}
          other -> parse_attribute(to_string(other))
        end)
    }
  end

  defp addr_type(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} when tuple_size(ip) == 8 -> "IP6"
      _ -> "IP4"
    end
  end

  @doc "Increments the SDP version."
  @spec increment(t()) :: t()
  def increment(%__MODULE__{vsn: vsn} = sdp), do: %{sdp | vsn: vsn + 1}

  @doc """
  Sets the direction of all medias to `status`, replacing any previous one,
  and increments the version.
  """
  @spec update(t(), media_status()) :: t()
  def update(%__MODULE__{medias: medias} = sdp, status)
      when status in [:inactive, :recvonly, :sendonly, :sendrecv] do
    medias =
      for media <- medias do
        attrs = Enum.reject(media.attributes, fn {name, _} -> name in @statuses end)
        %{media | attributes: attrs ++ [{Atom.to_string(status), []}]}
      end

    increment(%{sdp | medias: medias})
  end

  @doc """
  Returns `true` if `sdp2` has a higher version than `sdp1`. Returns `false`
  if any of them is `nil`.
  """
  @spec newer?(t() | nil, t() | nil) :: boolean()
  def newer?(%__MODULE__{vsn: vsn2}, %__MODULE__{vsn: vsn1}), do: vsn2 > vsn1
  def newer?(_, _), do: false

  ## ===================================================================
  ## Parsing
  ## ===================================================================

  @doc """
  Parses an SDP body. Both CRLF and LF line endings are accepted.
  """
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(bin) when is_binary(bin) do
    lines =
      case :binary.split(bin, "\r\n", [:global]) do
        [_] -> :binary.split(bin, "\n", [:global])
        lines -> lines
      end

    {:ok, session(for <<key, ?=, value::binary>> <- lines, do: {key, value})}
  rescue
    _ in [MatchError, ArgumentError, FunctionClauseError, CaseClauseError] -> :error
  end

  defp session([{?v, v}, {?o, o}, {?s, s} | rest]) do
    [user, id, vsn, type, addr_type, addr] = :binary.split(o, " ", [:global])

    sdp = %__MODULE__{
      sdp_vsn: v,
      user: user,
      id: String.to_integer(id),
      vsn: String.to_integer(vsn),
      address: {type, addr_type, addr},
      session: s
    }

    {sdp, rest} =
      {sdp, rest}
      |> optional(?i, :info)
      |> optional(?u, :uri)
      |> optional(?e, :email)
      |> optional(?p, :phone)
      |> optional(?c, :connect)
      |> many(?b, :bandwidth)
      |> times()
      |> optional(?z, :zone)
      |> optional(?k, :key)
      |> attributes()

    medias(rest, sdp, [])
  end

  defp medias([{?m, m} | rest], sdp, acc) do
    [name, ports, proto | fmt] = :binary.split(m, " ", [:global])

    {port, nports} =
      case :binary.split(ports, "/") do
        [port, nports] -> {String.to_integer(port), String.to_integer(nports)}
        [port] -> {String.to_integer(port), 1}
      end

    media = %Media{media: name, port: port, nports: nports, proto: proto, fmt: fmt}

    {media, rest} =
      {media, rest}
      |> optional(?i, :info)
      |> optional(?c, :connect)
      |> many(?b, :bandwidth)
      |> optional(?k, :key)
      |> attributes()

    medias(rest, sdp, [media | acc])
  end

  defp medias([], sdp, acc), do: %{sdp | medias: Enum.reverse(acc)}

  defp optional({struct, [{key, value} | rest]}, key, field),
    do: {Map.put(struct, field, field_value(field, value)), rest}

  defp optional(acc, _key, _field), do: acc

  defp field_value(:connect, value) do
    [type, addr_type, addr] = :binary.split(value, " ", [:global])
    {type, addr_type, addr}
  end

  defp field_value(_field, value), do: value

  defp many({struct, [{key, value} | rest]}, key, field),
    do: many({Map.update!(struct, field, &(&1 ++ [value])), rest}, key, field)

  defp many(acc, _key, _field), do: acc

  defp times({sdp, [{?t, t} | rest]}) do
    [start, stop] = :binary.split(t, " ")
    {reps, rest} = Enum.split_while(rest, &match?({?r, _}, &1))
    time = {String.to_integer(start), String.to_integer(stop), for({?r, r} <- reps, do: r)}
    times({%{sdp | time: sdp.time ++ [time]}, rest})
  end

  defp times(acc), do: acc

  defp attributes({struct, [{?a, a} | rest]}),
    do: attributes({%{struct | attributes: struct.attributes ++ [parse_attribute(a)]}, rest})

  defp attributes({struct, [{?b, b} | rest]}),
    do: attributes({%{struct | bandwidth: struct.bandwidth ++ [b]}, rest})

  defp attributes(acc), do: acc

  defp parse_attribute(value) do
    case :binary.split(value, ":") do
      [name] -> {name, []}
      [name, values] -> {name, :binary.split(values, " ", [:global])}
    end
  end

  ## ===================================================================
  ## Encoding
  ## ===================================================================

  @doc "Serializes an SDP, using CRLF line endings."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = sdp), do: IO.iodata_to_binary(to_iodata(sdp))

  @doc "Serializes an SDP as iodata."
  @spec to_iodata(t()) :: iodata()
  def to_iodata(%__MODULE__{} = sdp) do
    {type, addr_type, addr} = sdp.address

    [
      line(?v, sdp.sdp_vsn),
      line(?o, [
        sdp.user,
        ?\s,
        to_string(sdp.id),
        ?\s,
        to_string(sdp.vsn),
        ?\s,
        type,
        ?\s,
        addr_type,
        ?\s,
        addr
      ]),
      line(?s, sdp.session),
      line(?i, sdp.info),
      line(?u, sdp.uri),
      line(?e, sdp.email),
      line(?p, sdp.phone),
      address_line(sdp.connect),
      Enum.map(sdp.bandwidth, &line(?b, &1)),
      for {start, stop, reps} <- sdp.time do
        [line(?t, [to_string(start), ?\s, to_string(stop)]), Enum.map(reps, &line(?r, &1))]
      end,
      line(?z, sdp.zone),
      line(?k, sdp.key),
      Enum.map(sdp.attributes, &attribute_line/1),
      Enum.map(sdp.medias, &media/1)
    ]
  end

  defp media(%Media{} = media) do
    ports = if media.nports == 1, do: [], else: [?/, to_string(media.nports)]
    fmt = Enum.map(media.fmt, &[?\s, &1])

    [
      line(?m, [media.media, ?\s, to_string(media.port), ports, ?\s, media.proto, fmt]),
      line(?i, media.info),
      address_line(media.connect),
      Enum.map(media.bandwidth, &line(?b, &1)),
      line(?k, media.key),
      Enum.map(media.attributes, &attribute_line/1)
    ]
  end

  defp line(_key, nil), do: []
  defp line(key, value), do: [key, ?=, value, "\r\n"]

  defp address_line(nil), do: []
  defp address_line({type, addr_type, addr}), do: line(?c, [type, ?\s, addr_type, ?\s, addr])

  defp attribute_line({name, []}), do: line(?a, name)
  defp attribute_line({name, values}), do: line(?a, [name, ?:, Enum.intersperse(values, ?\s)])

  ## ===================================================================
  ## Messages
  ## ===================================================================

  @doc """
  Returns the SDP in the body of a message, if its Content-Type is
  `application/sdp`.
  """
  @spec from_message(Caracola.Message.t()) :: t() | nil
  def from_message(%Caracola.Message{content_type: {type, _}, body: body})
      when is_binary(body) and body != "" do
    with "application/sdp" <- Caracola.Util.ascii_downcase(type),
         {:ok, sdp} <- parse(body) do
      sdp
    else
      _ -> nil
    end
  end

  def from_message(_msg), do: nil

  @doc false
  # Sets the SDP as body of a message, with its Content-Type
  def put_body(%Caracola.Message{} = msg, %__MODULE__{} = sdp),
    do: %{msg | body: encode(sdp), content_type: {"application/sdp", []}}

  defimpl String.Chars do
    def to_string(sdp), do: Caracola.SDP.encode(sdp)
  end
end
