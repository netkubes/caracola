defmodule Caracola.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Caracola.{Digest, Message, Parser, SDP, Serializer, URI, Via}
  alias Caracola.SDP.Media

  ## ===================================================================
  ## Generators
  ## ===================================================================

  defp alnum(min \\ 1, max \\ 8),
    do: string(:alphanumeric, min_length: min, max_length: max)

  defp token, do: alnum() |> map(&String.downcase/1)

  defp domain do
    one_of([
      list_of(token(), min_length: 1, max_length: 3) |> map(&Enum.join(&1, ".")),
      list_of(integer(0..255), length: 4) |> map(&Enum.join(&1, ".")),
      list_of(integer(0..0xFFFF), length: 8)
      |> map(&"[#{Enum.map_join(&1, ":", fn n -> Integer.to_string(n, 16) end)}]")
    ])
  end

  defp port, do: one_of([constant(nil), integer(1..65_535)])

  # Header-level parameters can have quoted values
  defp params(max \\ 3, quoted? \\ true) do
    value =
      if quoted?,
        do: one_of([constant(nil), alnum(), map(alnum(), &~s("#{&1} x"))]),
        else: one_of([constant(nil), alnum()])

    list_of(tuple({token(), value}), max_length: max)
  end

  defp uri_headers, do: list_of(tuple({token(), one_of([constant(nil), alnum()])}), max_length: 2)

  defp uri(opts \\ []) do
    gen all(
          scheme <- member_of([:sip, :sips]),
          user <- one_of([constant(nil), alnum()]),
          pass <- if(user, do: one_of([constant(nil), alnum()]), else: constant(nil)),
          domain <- domain(),
          port <- port(),
          params <- params(3, false),
          headers <- uri_headers(),
          ext_params <- params(),
          disp <- one_of([constant(nil), alnum(), map(alnum(), &~s("#{&1} \\"x\\""))])
        ) do
      ext_params = Keyword.get(opts, :ext_params, []) ++ ext_params

      %URI{
        scheme: scheme,
        user: user,
        pass: pass,
        domain: domain,
        port: port,
        params: params,
        headers: headers,
        ext_params: ext_params,
        disp: disp
      }
    end
  end

  defp via do
    gen all(
          transport <- member_of([:udp, :tcp, :tls, :sctp, :ws, :wss]),
          domain <- domain(),
          port <- port(),
          branch <- alnum(),
          params <- params(2)
        ) do
      %Via{
        transport: transport,
        domain: domain,
        port: port,
        params: [{"branch", "z9hG4bK" <> branch} | params]
      }
    end
  end

  defp method do
    member_of([:invite, :ack, :bye, :options, :register, :subscribe, :notify, :message, "FOO"])
  end

  defp class do
    one_of([
      map(method(), &{:req, &1}),
      map(tuple({integer(100..699), alnum(1, 8)}), fn {code, reason} -> {:resp, code, reason} end)
    ])
  end

  defp message do
    gen all(
          class <- class(),
          ruri <- uri(),
          cseq_method <- method(),
          from_tag <- alnum(),
          from <- uri(ext_params: [{"tag", from_tag}]),
          to_tag <- one_of([constant(nil), alnum()]),
          to <- uri(ext_params: if(to_tag, do: [{"tag", to_tag}], else: [])),
          call_id <- alnum(1, 20),
          cseq <- integer(0..0xFFFFFFFF),
          vias <- list_of(via(), min_length: 1, max_length: 3),
          max_forwards <- one_of([constant(nil), integer(0..299)]),
          routes <- list_of(uri(), max_length: 2),
          contacts <- list_of(uri(), max_length: 2),
          expires <- one_of([constant(nil), integer(0..100_000)]),
          content_type <- one_of([constant(nil), tuple({constant("application/sdp"), params(1)})]),
          require <- list_of(token(), max_length: 2),
          supported <- list_of(token(), max_length: 2),
          event <- one_of([constant(nil), tuple({token(), params(1)})]),
          headers <- list_of(tuple({map(token(), &("x-" <> &1)), alnum()}), max_length: 3),
          body <- binary(max_length: 50)
        ) do
      {ruri, cseq_method} =
        case class do
          {:req, method} ->
            {%{ruri | disp: nil, headers: [], ext_params: [], ext_headers: []}, method}

          _ ->
            {nil, cseq_method}
        end

      event =
        case class do
          {:req, method} when method in [:subscribe, :notify] -> event || {"presence", []}
          _ -> event
        end

      %Message{
        class: class,
        ruri: ruri,
        from: from,
        from_tag: from_tag,
        to: to,
        to_tag: to_tag,
        call_id: call_id,
        cseq: {cseq, cseq_method},
        vias: vias,
        max_forwards: max_forwards,
        routes: routes,
        contacts: contacts,
        expires: expires,
        content_type: content_type,
        require: require,
        supported: supported,
        event: event,
        headers: headers,
        body: body
      }
    end
  end

  # Text without line breaks or leading spaces
  defp text, do: string(:printable, min_length: 1, max_length: 12) |> map(&clean/1)
  defp word, do: string([?!..?~], min_length: 1, max_length: 10)

  defp clean(bin) do
    case String.replace(bin, ["\r", "\n"], "") do
      "" -> "x"
      bin -> bin
    end
  end

  defp address, do: tuple({constant("IN"), member_of(["IP4", "IP6"]), word()})

  defp attribute do
    tuple({string([?a..?z, ?-], min_length: 1, max_length: 8), list_of(word(), max_length: 3)})
  end

  defp optional(gen), do: one_of([constant(nil), gen])

  defp sdp do
    media =
      gen all(
            name <- word(),
            port <- integer(0..65_535),
            nports <- integer(1..4),
            proto <- word(),
            fmt <- list_of(word(), max_length: 3),
            info <- optional(text()),
            connect <- optional(address()),
            bandwidth <- list_of(word(), max_length: 2),
            key <- optional(text()),
            attributes <- list_of(attribute(), max_length: 4)
          ) do
        %Media{
          media: name,
          port: port,
          nports: nports,
          proto: proto,
          fmt: fmt,
          info: info,
          connect: connect,
          bandwidth: bandwidth,
          key: key,
          attributes: attributes
        }
      end

    gen all(
          user <- word(),
          id <- non_negative_integer(),
          vsn <- non_negative_integer(),
          address <- address(),
          session <- text(),
          [info, uri, email, phone, zone, key] <- list_of(optional(text()), length: 6),
          connect <- optional(address()),
          bandwidth <- list_of(word(), max_length: 2),
          time <-
            list_of(
              tuple(
                {non_negative_integer(), non_negative_integer(), list_of(text(), max_length: 2)}
              )
            ),
          attributes <- list_of(attribute(), max_length: 4),
          medias <- list_of(media, max_length: 3)
        ) do
      %SDP{
        user: user,
        id: id,
        vsn: vsn,
        address: address,
        session: session,
        info: info,
        uri: uri,
        email: email,
        phone: phone,
        connect: connect,
        bandwidth: bandwidth,
        time: time,
        zone: zone,
        key: key,
        attributes: attributes,
        medias: medias
      }
    end
  end

  ## ===================================================================
  ## Properties
  ## ===================================================================

  property "uris survive an encode/parse round trip" do
    check all(uri <- uri()) do
      assert URI.parse(IO.iodata_to_binary(URI.encode(uri))) == {:ok, [uri]}
    end
  end

  property "uri lists survive an encode/parse round trip" do
    check all(uris <- list_of(uri(), min_length: 1, max_length: 4)) do
      assert URI.parse(IO.iodata_to_binary(URI.encode(uris))) == {:ok, uris}
    end
  end

  property "vias survive an encode/parse round trip" do
    check all(via <- via()) do
      assert Via.parse(IO.iodata_to_binary(Via.encode(via))) == {:ok, [via]}
    end
  end

  property "messages survive an encode/parse round trip" do
    check all(msg <- message(), transport <- member_of([:udp, :tcp])) do
      bin = Serializer.encode(msg)
      assert Parser.parse(bin, transport) == {:ok, msg, ""}
    end
  end

  property "truncated messages are partial on stream transports" do
    check all(msg <- message(), cut <- float(min: 0.0, max: 1.0)) do
      bin = Serializer.encode(msg)
      len = trunc((byte_size(bin) - 1) * cut)
      assert Parser.parse(binary_part(bin, 0, len), :tcp) == :partial
    end
  end

  property "the parser never crashes" do
    check all(
            bin <- one_of([binary(), map(message(), &mutate(Serializer.encode(&1)))]),
            transport <- member_of([:udp, :tcp])
          ) do
      case Parser.parse(bin, transport) do
        {:ok, %Message{}, rest} when is_binary(rest) -> :ok
        :partial -> :ok
        {:error, %Caracola.ParseError{} = error} -> Serializer.error_response(error)
      end
    end
  end

  property "sdps survive an encode/parse round trip" do
    check all(sdp <- sdp()) do
      assert SDP.parse(SDP.encode(sdp)) == {:ok, sdp}
    end
  end

  property "digest credentials are verified" do
    check all(
            user <- text(),
            password <- text(),
            realm <- text(),
            nonce <- text(),
            opaque <- optional(text()),
            ruri <- uri(),
            method <- method(),
            nc <- integer(1..1000)
          ) do
      uri = %{ruri | disp: nil, ext_params: [], ext_headers: []}
      opts = [method: method, uri: uri, user: user, password: password, nc: nc]
      {:ok, auth} = Digest.authorization(Digest.challenge(realm, nonce, opaque), opts)
      assert {:ok, creds} = Digest.parse(auth)
      assert %{username: ^user, realm: ^realm, nonce: ^nonce} = creds
      assert Digest.verify(creds, method, password) == true
      assert Digest.verify(creds, method, password <> "x") == false
    end
  end

  # Flips some bytes of a binary
  defp mutate(bin) do
    size = byte_size(bin)

    Enum.reduce(1..3, bin, fn _, acc ->
      pos = :rand.uniform(size) - 1
      <<pre::binary-size(^pos), _, post::binary>> = acc
      <<pre::binary, :rand.uniform(256) - 1, post::binary>>
    end)
  end
end
