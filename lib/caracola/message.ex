defmodule Caracola.Message do
  @moduledoc """
  A parsed SIP request or response. Equivalent to NkSIP's `#sipmsg{}`.

  The most used headers are pre-parsed into their own fields. Any other
  header is kept, in order, in `headers` as `{lowercase_name, raw_value}`.

  Messages handled by a service also carry the `service` id, a unique `id`,
  the transport `port` they were received from or sent through and the
  `dialog_id` of the dialog they belong to (see `Caracola.Dialog.handle/1`).

  Methods are lowercase atoms for the ones defined in RFCs (`:invite`,
  `:register`...) and strings for any other.
  """

  alias Caracola.{Tokens, URI, Via}

  @typedoc "A SIP method, as an atom (`:invite`, `:register`...) or a binary for unknown ones."
  @type method ::
          :invite
          | :ack
          | :cancel
          | :bye
          | :options
          | :register
          | :subscribe
          | :notify
          | :publish
          | :refer
          | :message
          | :info
          | :prack
          | :update
          | String.t()

  @typedoc "The class of a message: `{:req, method}` or `{:resp, code, reason}`."
  @type class :: {:req, method()} | {:resp, 100..699, String.t()}

  @typedoc "A SIP message, request or response, parsed."
  @type t :: %__MODULE__{
          class: class(),
          ruri: URI.t() | nil,
          vias: [Via.t()],
          from: URI.t(),
          from_tag: String.t() | nil,
          to: URI.t(),
          to_tag: String.t() | nil,
          call_id: String.t(),
          cseq: {non_neg_integer(), method()},
          max_forwards: non_neg_integer() | nil,
          routes: [URI.t()],
          contacts: [URI.t()],
          content_type: Tokens.token() | nil,
          require: [String.t()],
          supported: [String.t()],
          expires: non_neg_integer() | nil,
          event: Tokens.token() | nil,
          headers: [{String.t(), String.t()}],
          body: binary(),
          service: term(),
          id: String.t() | nil,
          port: Caracola.Transport.Port.t() | nil,
          dialog_id: String.t() | nil
        }

  defstruct [
    :class,
    :ruri,
    :from,
    :from_tag,
    :to,
    :to_tag,
    :call_id,
    :cseq,
    :max_forwards,
    :content_type,
    :expires,
    :event,
    :service,
    :id,
    :port,
    :dialog_id,
    vias: [],
    routes: [],
    contacts: [],
    require: [],
    supported: [],
    headers: [],
    body: ""
  ]

  @methods ~w(INVITE ACK CANCEL BYE OPTIONS REGISTER SUBSCRIBE NOTIFY PUBLISH REFER MESSAGE INFO PRACK UPDATE)

  @doc """
  Converts a method from its wire form. Method names are case-sensitive.

      iex> Caracola.Message.to_method("INVITE")
      :invite
      iex> Caracola.Message.to_method("invite")
      "invite"
  """
  @spec to_method(String.t()) :: method()
  for method <- @methods do
    def to_method(unquote(method)), do: unquote(method |> String.downcase() |> String.to_atom())
  end

  def to_method(method) when is_binary(method), do: method

  @doc "Converts a method to its wire form."
  @spec method_to_string(method()) :: String.t()
  for method <- @methods do
    def method_to_string(unquote(method |> String.downcase() |> String.to_atom())),
      do: unquote(method)
  end

  def method_to_string(method) when is_binary(method), do: method

  @doc "Returns the method of a request, or of the request a response belongs to."
  @spec method(t()) :: method()
  def method(%__MODULE__{class: {:req, method}}), do: method
  def method(%__MODULE__{cseq: {_, method}}), do: method

  @doc "Gets all values of a non pre-parsed header."
  @spec get_headers(t(), String.t()) :: [String.t()]
  def get_headers(%__MODULE__{headers: headers}, name) do
    name = Caracola.Headers.normalize_name(name)
    for {^name, value} <- headers, do: value
  end

  @doc """
  Gets the values of any header as strings, including the pre-parsed ones.

      iex> {:ok, msg, _} = Caracola.Parser.parse("OPTIONS sip:a SIP/2.0\\r\\nVia: SIP/2.0/UDP h\\r\\nFrom: <sip:a>;tag=1\\r\\nTo: <sip:b>\\r\\nCall-ID: 1\\r\\nCSeq: 1 OPTIONS\\r\\nSupported: path, 100rel\\r\\n\\r\\n")
      iex> Caracola.Message.header(msg, "Supported")
      ["path, 100rel"]
      iex> Caracola.Message.header(msg, "from")
      ["<sip:a>;tag=1"]
  """
  @spec header(t(), String.t()) :: [String.t()]
  def header(%__MODULE__{} = msg, name), do: values(Caracola.Headers.normalize_name(name), msg)

  defp values("from", msg), do: [encode(URI.encode(msg.from))]
  defp values("to", msg), do: [encode(URI.encode(msg.to))]
  defp values("call-id", msg), do: [msg.call_id]
  defp values("cseq", msg), do: [cseq(msg.cseq)]

  defp values("via", msg),
    do: non_empty(msg.vias, &Enum.map_join(&1, ", ", fn via -> encode(Via.encode(via)) end))

  defp values("route", msg), do: non_empty(msg.routes, &encode(URI.encode(&1)))
  defp values("contact", msg), do: non_empty(msg.contacts, &encode(URI.encode(&1)))
  defp values("require", msg), do: non_empty(msg.require, &Enum.join(&1, ", "))
  defp values("supported", msg), do: non_empty(msg.supported, &Enum.join(&1, ", "))
  defp values("content-type", msg), do: optional(msg.content_type, &encode(Tokens.encode(&1)))
  defp values("event", msg), do: optional(msg.event, &encode(Tokens.encode(&1)))
  defp values("expires", msg), do: optional(msg.expires, &Integer.to_string/1)
  defp values("max-forwards", msg), do: optional(msg.max_forwards, &Integer.to_string/1)
  defp values(name, msg), do: for({^name, value} <- msg.headers, do: value)

  defp optional(nil, _fun), do: []
  defp optional(value, fun), do: [fun.(value)]

  defp cseq({num, method}), do: "#{num} #{method_to_string(method)}"
  defp non_empty([], _fun), do: []
  defp non_empty(list, fun), do: [fun.(list)]
  defp encode(iodata), do: IO.iodata_to_binary(iodata)

  @doc """
  Removes all the values of a header. From, To, Call-ID, CSeq and Via
  cannot be removed.

      iex> {:ok, msg} = Caracola.Message.update_header(%Caracola.Message{}, :add, "X-Data", "a")
      iex> Caracola.Message.remove_header(msg, :x_data).headers
      []
  """
  @spec remove_header(t(), String.t() | atom()) :: t()
  def remove_header(%__MODULE__{} = msg, name) do
    case name |> to_string() |> String.replace("_", "-") |> Caracola.Headers.normalize_name() do
      "route" -> %{msg | routes: []}
      "contact" -> %{msg | contacts: []}
      "require" -> %{msg | require: []}
      "supported" -> %{msg | supported: []}
      name when name in ["from", "to", "call-id", "cseq", "via"] -> msg
      name -> %{msg | headers: Enum.reject(msg.headers, &(elem(&1, 0) == name))}
    end
  end

  @doc """
  Adds (at the end), inserts (at the beginning) or replaces the values of a
  header. Pre-parsed headers are parsed and stored in their fields;
  `From` and `To` also update the tags.

  Values can be strings, integers, atoms, lists of them (joined with `", "`),
  `Caracola.URI` structs and tokens. Replacing with `[]` removes the header.
  `Via`, `CSeq` and `Content-Length` cannot be changed.

      iex> msg = %Caracola.Message{}
      iex> {:ok, msg} = Caracola.Message.update_header(msg, :replace, "From", "<sip:a@b>;tag=t1")
      iex> {msg.from.user, msg.from_tag}
      {"a", "t1"}
      iex> {:ok, msg} = Caracola.Message.update_header(msg, :add, "X-Data", ["a", 1])
      iex> msg.headers
      [{"x-data", "a, 1"}]
      iex> Caracola.Message.update_header(msg, :add, "Contact", "<sip:a")
      {:error, {:invalid, "contact"}}
  """
  @spec update_header(t(), :add | :insert | :replace, String.t() | atom(), term()) ::
          {:ok, t()} | {:error, {:invalid, String.t()}}
  def update_header(%__MODULE__{} = msg, op, name, value) when op in [:add, :insert, :replace] do
    name = name |> to_string() |> String.replace("_", "-") |> Caracola.Headers.normalize_name()

    case put_header(msg, op, name, value) do
      {:ok, msg} -> {:ok, msg}
      :error -> {:error, {:invalid, name}}
    end
  end

  defp put_header(msg, _op, name, value) when name in ["from", "to"] do
    case to_uris(value) do
      {:ok, [uri]} when name == "from" -> {:ok, %{msg | from: uri, from_tag: uri_tag(uri)}}
      {:ok, [uri]} -> {:ok, %{msg | to: uri, to_tag: uri_tag(uri)}}
      _ -> :error
    end
  end

  defp put_header(msg, op, "contact", value) do
    with {:ok, uris} <- to_uris(value),
         do: {:ok, %{msg | contacts: combine(op, msg.contacts, uris)}}
  end

  defp put_header(msg, op, "route", value) do
    with {:ok, uris} <- to_uris(value), do: {:ok, %{msg | routes: combine(op, msg.routes, uris)}}
  end

  defp put_header(msg, op, name, value) when name in ["require", "supported"] do
    with {:ok, words} <- to_words(value) do
      field = String.to_existing_atom(name)
      {:ok, Map.put(msg, field, combine(op, Map.fetch!(msg, field), words))}
    end
  end

  defp put_header(msg, _op, name, value) when name in ["content-type", "event"] do
    with {:ok, token} <- to_token(value) do
      if name == "event",
        do: {:ok, %{msg | event: token}},
        else: {:ok, %{msg | content_type: token}}
    end
  end

  defp put_header(msg, _op, name, value) when name in ["expires", "max-forwards"] do
    with {:ok, int} <- to_int(value) do
      if name == "expires",
        do: {:ok, %{msg | expires: int}},
        else: {:ok, %{msg | max_forwards: int}}
    end
  end

  defp put_header(msg, _op, "call-id", value) when is_binary(value) and value != "",
    do: {:ok, %{msg | call_id: value}}

  defp put_header(_msg, _op, name, _value)
       when name in ["call-id", "via", "cseq", "content-length"],
       do: :error

  defp put_header(msg, op, name, value) do
    with {:ok, values} <- to_strings(value) do
      new = for v <- values, do: {name, v}

      headers =
        case op do
          :add -> msg.headers ++ new
          :insert -> new ++ msg.headers
          :replace -> Enum.reject(msg.headers, &(elem(&1, 0) == name)) ++ new
        end

      {:ok, %{msg | headers: headers}}
    end
  end

  defp uri_tag(uri) do
    case URI.get_ext_param(uri, "tag") do
      {:ok, tag} -> tag
      :error -> nil
    end
  end

  defp combine(:add, old, new), do: old ++ new
  defp combine(:insert, old, new), do: new ++ old
  defp combine(:replace, _old, new), do: new

  defp to_uris(%URI{} = uri), do: {:ok, [uri]}
  defp to_uris(bin) when is_binary(bin), do: URI.parse(bin)

  defp to_uris(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case to_uris(item) do
        {:ok, uris} -> {:cont, {:ok, acc ++ uris}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp to_uris(_), do: :error

  defp to_words(bin) when is_binary(bin), do: {:ok, String.split(bin, [",", " "], trim: true)}

  defp to_words(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) or is_atom(&1))),
      do: {:ok, Enum.map(list, &to_string/1)},
      else: :error
  end

  defp to_words(_), do: :error

  defp to_token(nil), do: {:ok, nil}
  defp to_token({name, params} = token) when is_binary(name) and is_list(params), do: {:ok, token}

  defp to_token(bin) when is_binary(bin) do
    case Tokens.parse(bin) do
      {:ok, [token]} -> {:ok, token}
      _ -> :error
    end
  end

  defp to_token(_), do: :error

  defp to_int(nil), do: {:ok, nil}
  defp to_int(int) when is_integer(int) and int >= 0, do: {:ok, int}
  defp to_int(bin) when is_binary(bin), do: Caracola.Util.to_integer(bin)
  defp to_int(_), do: :error

  defp to_strings([]), do: {:ok, []}
  defp to_strings(list) when is_list(list), do: with({:ok, bin} <- join(list), do: {:ok, [bin]})
  defp to_strings(value), do: with({:ok, bin} <- to_value(value), do: {:ok, [bin]})

  defp join(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case to_value(item) do
        {:ok, bin} -> {:cont, {:ok, acc ++ [bin]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, bins} -> {:ok, Enum.join(bins, ", ")}
      :error -> :error
    end
  end

  defp to_value(bin) when is_binary(bin), do: {:ok, bin}
  defp to_value(int) when is_integer(int), do: {:ok, Integer.to_string(int)}

  defp to_value(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: {:ok, Atom.to_string(atom)}

  defp to_value(%URI{} = uri), do: {:ok, encode(URI.encode(uri))}

  defp to_value({name, params}) when is_binary(name) and is_list(params),
    do: {:ok, encode(Tokens.encode({name, params}))}

  defp to_value(_), do: :error
end
