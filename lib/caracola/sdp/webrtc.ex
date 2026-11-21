defmodule Caracola.SDP.WebRTC do
  @moduledoc """
  SDP utilities for WebRTC endpoints. Successor of NkSIP's `nksip_sdp_util`.

    * ICE (RFC 8839): credentials, and candidates as browsers give and take
      them (`RTCIceCandidate`: `candidate`, `sdpMid` and `sdpMLineIndex`),
      to add them to an SDP or extract them.
    * Trickle ICE over SIP (RFC 8840): the `application/trickle-ice-sdpfrag`
      bodies of the INFO requests of the `trickle-ice` Info Package.
    * DTLS-SRTP (RFC 5763, RFC 8842): fingerprint and setup role.
    * BUNDLE (RFC 8843), `mid` and rtcp-mux (RFC 5761).
    * Codecs: listing, keeping or removing them by name.

  Values at media level take precedence over session level ones.

      iex> {:ok, sdp} = Caracola.SDP.parse(\"""
      ...> v=0\\r
      ...> o=- 1 1 IN IP4 127.0.0.1\\r
      ...> s=-\\r
      ...> t=0 0\\r
      ...> a=group:BUNDLE 0\\r
      ...> a=ice-ufrag:abcd\\r
      ...> a=ice-pwd:0123456789012345678901\\r
      ...> m=audio 9 UDP/TLS/RTP/SAVPF 111\\r
      ...> c=IN IP4 0.0.0.0\\r
      ...> a=mid:0\\r
      ...> a=rtcp-mux\\r
      ...> a=setup:actpass\\r
      ...> a=fingerprint:sha-256 AB:CD\\r
      ...> a=rtpmap:111 opus/48000/2\\r
      ...> \""")
      iex> alias Caracola.SDP.WebRTC
      iex> {WebRTC.bundle(sdp), WebRTC.ice(sdp).ufrag, WebRTC.setup(sdp), WebRTC.fingerprint(sdp)}
      {["0"], "abcd", :actpass, {"sha-256", "AB:CD"}}
  """

  alias Caracola.SDP
  alias Caracola.SDP.Media

  @typedoc """
  An ICE candidate as a browser gives and takes it: the attribute value
  (`"candidate:..."`, without `a=`), the `mid` of its media (`nil` if
  unknown) and its index.
  """
  @type candidate :: %{candidate: String.t(), mid: String.t() | nil, index: non_neg_integer()}

  @typedoc "A codec of a media: payload type, encoding name, clock rate and parameters."
  @type codec :: %{
          pt: String.t(),
          name: String.t(),
          rate: pos_integer() | nil,
          channels: pos_integer() | nil,
          fmtp: [String.t()],
          rtcp_fb: [String.t()]
        }

  @typedoc "A DTLS setup role (RFC 4145)."
  @type setup :: :actpass | :active | :passive | :holdconn

  @sdpfrag "application/trickle-ice-sdpfrag"

  @doc "The Content-Type of trickle ICE bodies (RFC 8840)."
  @spec sdpfrag_content_type() :: String.t()
  def sdpfrag_content_type, do: @sdpfrag

  ## ===================================================================
  ## Medias
  ## ===================================================================

  @doc "The `mid` of a media (`nil` if it has none)."
  @spec mid(Media.t()) :: String.t() | nil
  def mid(%Media{attributes: attrs}), do: first(attrs, "mid")

  @doc "The mids of the BUNDLE group of an SDP (RFC 8843), `[]` if none."
  @spec bundle(SDP.t()) :: [String.t()]
  def bundle(%SDP{attributes: attrs}) do
    Enum.find_value(attrs, [], fn
      {"group", ["BUNDLE" | mids]} -> mids
      _ -> nil
    end)
  end

  @doc "`true` if the media multiplexes RTP and RTCP (RFC 5761)."
  @spec rtcp_mux?(Media.t()) :: boolean()
  def rtcp_mux?(%Media{attributes: attrs}), do: List.keymember?(attrs, "rtcp-mux", 0)

  @doc "`true` if the media uses a secure RTP profile (`RTP/SAVP`, `UDP/TLS/RTP/SAVPF`...)."
  @spec secure?(Media.t()) :: boolean()
  def secure?(%Media{proto: proto}), do: String.contains?(proto, "SAVP")

  ## ===================================================================
  ## ICE
  ## ===================================================================

  @doc """
  ICE credentials and options of a media (by index), or of the session:
  `%{ufrag, pwd, options, lite}`.
  """
  @spec ice(SDP.t(), non_neg_integer()) :: %{
          ufrag: String.t() | nil,
          pwd: String.t() | nil,
          options: [String.t()],
          lite: boolean()
        }
  def ice(%SDP{} = sdp, index \\ 0) do
    %{
      ufrag: value(sdp, index, "ice-ufrag"),
      pwd: value(sdp, index, "ice-pwd"),
      options: values(sdp, index, "ice-options"),
      lite: List.keymember?(sdp.attributes, "ice-lite", 0)
    }
  end

  @doc """
  The ICE candidates of an SDP, in the order of their medias.
  """
  @spec candidates(SDP.t()) :: [candidate()]
  def candidates(%SDP{medias: medias}) do
    for {media, index} <- Enum.with_index(medias),
        {"candidate", values} <- media.attributes,
        do: %{candidate: "candidate:" <> Enum.join(values, " "), mid: mid(media), index: index}
  end

  @doc """
  Adds ICE candidates to the medias they belong to: by `mid` if the media
  has one, or by index. Candidates for unknown medias are ignored.
  """
  @spec add_candidates(SDP.t(), [candidate()]) :: SDP.t()
  def add_candidates(%SDP{medias: medias} = sdp, candidates) do
    medias =
      for {media, index} <- Enum.with_index(medias) do
        attrs =
          for %{candidate: "candidate:" <> line} = c <- candidates,
              belongs?(c, mid(media), index),
              do: {"candidate", String.split(line, " ")}

        %{media | attributes: media.attributes ++ attrs}
      end

    %{sdp | medias: medias}
  end

  defp belongs?(candidate, nil, index), do: Map.get(candidate, :index) == index
  defp belongs?(candidate, mid, _index), do: Map.get(candidate, :mid) == mid

  @doc """
  Parses a candidate (with or without the `candidate:` prefix).

      iex> Caracola.SDP.WebRTC.parse_candidate("candidate:1 1 udp 2122260223 192.0.2.1 54400 typ srflx raddr 10.0.0.1 rport 54400 generation 0")
      {:ok,
       %{foundation: "1", component: 1, transport: "udp", priority: 2122260223,
         address: "192.0.2.1", port: 54400, type: "srflx", raddr: "10.0.0.1",
         rport: 54400, extensions: [{"generation", "0"}]}}
  """
  @spec parse_candidate(String.t()) :: {:ok, map()} | :error
  def parse_candidate("candidate:" <> line), do: parse_candidate(line)

  def parse_candidate(line) do
    with [foundation, component, transport, priority, address, port, "typ", type | rest] <-
           String.split(line, " ", trim: true),
         {component, ""} <- Integer.parse(component),
         {priority, ""} <- Integer.parse(priority),
         {port, ""} <- Integer.parse(port),
         {:ok, extensions} <- pairs(rest, []) do
      {raddr, extensions} = pop(extensions, "raddr")
      {rport, extensions} = pop(extensions, "rport")

      {:ok,
       %{
         foundation: foundation,
         component: component,
         transport: String.downcase(transport),
         priority: priority,
         address: address,
         port: port,
         type: type,
         raddr: raddr,
         rport: rport && String.to_integer(rport),
         extensions: extensions
       }}
    else
      _ -> :error
    end
  end

  defp pairs([key, value | rest], acc), do: pairs(rest, [{key, value} | acc])
  defp pairs([], acc), do: {:ok, Enum.reverse(acc)}
  defp pairs(_odd, _acc), do: :error

  defp pop(list, key) do
    case List.keytake(list, key, 0) do
      {{_, value}, list} -> {value, list}
      nil -> {nil, list}
    end
  end

  ## ===================================================================
  ## Trickle ICE (RFC 8840)
  ## ===================================================================

  @doc """
  The body of a trickle ICE INFO (`application/trickle-ice-sdpfrag`): the
  ICE credentials of `sdp` (the local one), an `m=` line (with port 9) and
  `mid` for each media, and the candidates, by mid or index. With
  `end_of_candidates: true`, the `end-of-candidates` attribute is added.
  """
  @spec sdpfrag(SDP.t(), [candidate()], keyword()) :: String.t()
  def sdpfrag(%SDP{} = sdp, candidates, opts \\ []) do
    %{ufrag: ufrag, pwd: pwd} = ice(sdp)
    with_candidates = add_candidates(sdp, candidates)

    medias =
      for media <- with_candidates.medias do
        [
          "m=#{media.media} 9 #{media.proto} #{Enum.join(media.fmt, " ")}\r\n",
          if(mid = mid(media), do: "a=mid:#{mid}\r\n", else: []),
          for(
            {"candidate", values} <- media.attributes,
            do: ["a=candidate:", Enum.join(values, " "), "\r\n"]
          )
        ]
      end

    IO.iodata_to_binary([
      if(ufrag, do: "a=ice-ufrag:#{ufrag}\r\n", else: []),
      if(pwd, do: "a=ice-pwd:#{pwd}\r\n", else: []),
      medias,
      if(opts[:end_of_candidates], do: "a=end-of-candidates\r\n", else: [])
    ])
  end

  @doc """
  Parses a trickle ICE body: `%{ufrag, pwd, candidates, end_of_candidates}`.
  Candidates get the mid and index of their `m=` line.
  """
  @spec parse_sdpfrag(String.t()) :: {:ok, map()} | :error
  def parse_sdpfrag(body) when is_binary(body) do
    lines = String.split(body, ["\r\n", "\n"], trim: true)

    acc = %{ufrag: nil, pwd: nil, candidates: [], end_of_candidates: false, index: -1, mid: nil}

    lines
    |> Enum.reduce_while(acc, &sdpfrag_line/2)
    |> case do
      :error ->
        :error

      acc ->
        {:ok,
         acc
         |> Map.update!(:candidates, &Enum.reverse/1)
         |> Map.drop([:index, :mid])}
    end
  end

  defp sdpfrag_line("m=" <> _, acc), do: {:cont, %{acc | index: acc.index + 1, mid: nil}}
  defp sdpfrag_line("a=ice-ufrag:" <> ufrag, acc), do: {:cont, %{acc | ufrag: ufrag}}
  defp sdpfrag_line("a=ice-pwd:" <> pwd, acc), do: {:cont, %{acc | pwd: pwd}}
  defp sdpfrag_line("a=end-of-candidates", acc), do: {:cont, %{acc | end_of_candidates: true}}

  # The mid comes before the candidates of its media
  defp sdpfrag_line("a=mid:" <> mid, acc) do
    candidates =
      Enum.map(acc.candidates, fn
        %{index: index, mid: nil} = c when index == acc.index -> %{c | mid: mid}
        c -> c
      end)

    {:cont, %{acc | mid: mid, candidates: candidates}}
  end

  defp sdpfrag_line("a=candidate:" <> _ = "a=" <> candidate, acc) do
    c = %{candidate: candidate, mid: acc.mid, index: max(acc.index, 0)}
    {:cont, %{acc | candidates: [c | acc.candidates]}}
  end

  defp sdpfrag_line(<<_, ?=, _::binary>>, acc), do: {:cont, acc}
  defp sdpfrag_line(_line, _acc), do: {:halt, :error}

  ## ===================================================================
  ## DTLS-SRTP
  ## ===================================================================

  @doc """
  The DTLS fingerprint of a media (by index) or of the session:
  `{hash_function, value}`, or `nil`.
  """
  @spec fingerprint(SDP.t(), non_neg_integer()) :: {String.t(), String.t()} | nil
  def fingerprint(%SDP{} = sdp, index \\ 0) do
    case values(sdp, index, "fingerprint") do
      [hash, value] -> {String.downcase(hash), value}
      _ -> nil
    end
  end

  @doc "The DTLS setup role of a media (by index) or of the session (RFC 4145)."
  @spec setup(SDP.t(), non_neg_integer()) :: setup() | nil
  def setup(%SDP{} = sdp, index \\ 0) do
    case value(sdp, index, "setup") do
      "actpass" -> :actpass
      "active" -> :active
      "passive" -> :passive
      "holdconn" -> :holdconn
      _ -> nil
    end
  end

  @doc """
  The setup role of an answer for the role of the offer (RFC 5763 §5:
  the answerer is `active` if it can).

      iex> Caracola.SDP.WebRTC.answer_setup(:actpass)
      :active
      iex> Caracola.SDP.WebRTC.answer_setup(:active)
      :passive
  """
  @spec answer_setup(setup() | nil) :: setup()
  def answer_setup(:active), do: :passive
  def answer_setup(:holdconn), do: :holdconn
  def answer_setup(_offer), do: :active

  ## ===================================================================
  ## Codecs
  ## ===================================================================

  @doc "The codecs of a media, in order of preference."
  @spec codecs(Media.t()) :: [codec()]
  def codecs(%Media{fmt: fmt, attributes: attrs}) do
    for pt <- fmt do
      {name, rate, channels} =
        case attr_for(attrs, "rtpmap", pt) do
          [encoding | _] -> encoding(encoding)
          nil -> {pt, nil, nil}
        end

      %{
        pt: pt,
        name: name,
        rate: rate,
        channels: channels,
        fmtp: attr_for(attrs, "fmtp", pt) || [],
        rtcp_fb: for({"rtcp-fb", [^pt | fb]} <- attrs, do: Enum.join(fb, " "))
      }
    end
  end

  defp encoding(encoding) do
    case String.split(encoding, "/") do
      [name, rate, channels] -> {name, String.to_integer(rate), String.to_integer(channels)}
      [name, rate] -> {name, String.to_integer(rate), nil}
      [name] -> {name, nil, nil}
    end
  end

  @doc """
  Keeps only the codecs with these names (case insensitive) in the medias
  of type `media` (as `"audio"`), and the retransmission (`rtx`) codecs of
  the kept ones.
  """
  @spec keep_codecs(SDP.t(), String.t(), [String.t()]) :: SDP.t()
  def keep_codecs(%SDP{} = sdp, media, names),
    do: filter_codecs(sdp, media, &(String.downcase(&1.name) in downcase(names)))

  @doc """
  Removes the codecs with these names (case insensitive) from the medias of
  type `media`, and the retransmission (`rtx`) codecs of the removed ones.
  """
  @spec remove_codecs(SDP.t(), String.t(), [String.t()]) :: SDP.t()
  def remove_codecs(%SDP{} = sdp, media, names),
    do: filter_codecs(sdp, media, &(String.downcase(&1.name) not in downcase(names)))

  defp filter_codecs(%SDP{medias: medias} = sdp, type, keep?) do
    medias =
      for media <- medias do
        if media.media == type, do: filter_media(media, keep?), else: media
      end

    %{sdp | medias: medias}
  end

  defp filter_media(media, keep?) do
    codecs = codecs(media)
    kept = for c <- codecs, String.downcase(c.name) != "rtx", keep?.(c), do: c.pt

    # rtx codecs follow the codec of their apt parameter
    rtx =
      for %{name: name, fmtp: fmtp, pt: pt} <- codecs,
          String.downcase(name) == "rtx",
          Enum.any?(
            fmtp,
            &(String.trim_trailing(&1, ";") in Enum.map(kept, fn k -> "apt=" <> k end))
          ),
          do: pt

    pts = kept ++ rtx

    attrs =
      Enum.filter(media.attributes, fn
        {name, [pt | _]} when name in ["rtpmap", "fmtp", "rtcp-fb"] -> pt in pts or pt == "*"
        _ -> true
      end)

    %{media | fmt: Enum.filter(media.fmt, &(&1 in pts)), attributes: attrs}
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp downcase(names), do: Enum.map(names, &String.downcase/1)

  defp first(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, [value | _]} -> value
      _ -> nil
    end
  end

  defp attr_for(attrs, name, pt) do
    Enum.find_value(attrs, fn
      {^name, [^pt | rest]} -> rest
      _ -> nil
    end)
  end

  # Values of an attribute of a media, or else of the session
  defp values(%SDP{medias: medias, attributes: attrs}, index, name) do
    media_attrs =
      case Enum.at(medias, index) do
        %Media{attributes: media_attrs} -> media_attrs
        nil -> []
      end

    case List.keyfind(media_attrs, name, 0) || List.keyfind(attrs, name, 0) do
      {_, values} -> values
      nil -> []
    end
  end

  defp value(sdp, index, name) do
    case values(sdp, index, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
