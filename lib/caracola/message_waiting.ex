defmodule Caracola.MessageWaiting do
  @moduledoc """
  Message waiting indication (RFC 3842): the `message-summary` event
  package, with `application/simple-message-summary` bodies, that turns on
  the message lamp of phones.

  ```
  defmodule MyVoicemail do
    use Malla.Service,
      plugins: [Caracola.MessageWaiting],
      sip: [listen: "sip:all:5060"]
  end

  Caracola.MessageWaiting.put(MyVoicemail, {:sip, "alice", "example.com"}, %{
    voice: %{new: 2, old: 8}
  })
  ```

  The plugin is built on `Caracola.Notifier`: it accepts SUBSCRIBEs to the
  `message-summary` event of any AOR (see `sip_notifier_authorize/4`
  there), and notifies the watchers of an AOR when the service sets its
  summary with `put/3`. The mailboxes themselves are up to the
  application.

  A summary has, for each message class (`:voice`, `:fax`, `:pager`,
  `:multimedia`, `:text` and `:none`), the number of `:new` and `:old`
  messages, and optionally of `:urgent_new` and `:urgent_old` ones, and
  an optional `:account` (the URI of the mailbox). Messages are waiting if
  there is any new one.

  User agents read the NOTIFYs (or the unsolicited NOTIFYs of PBXs, see
  `sip_unsolicited_notify/2`) with `decode/1`.
  """

  use Malla.Plugin, plugin_deps: [Caracola.Notifier]

  alias Caracola.Notifier

  @content_type "application/simple-message-summary"
  @event "message-summary"

  @classes [
    voice: "Voice-Message",
    fax: "Fax-Message",
    pager: "Pager-Message",
    multimedia: "Multimedia-Message",
    text: "Text-Message",
    none: "None"
  ]

  @typedoc "A message class of a message-summary (RFC 3842)."
  @type class :: :voice | :fax | :pager | :multimedia | :text | :none
  @typedoc "The counters of a message class: new, old, urgent new and urgent old."
  @type counts :: %{
          optional(:new) => non_neg_integer(),
          optional(:old) => non_neg_integer(),
          optional(:urgent_new) => non_neg_integer(),
          optional(:urgent_old) => non_neg_integer()
        }

  @typedoc "A message summary, as given to `put/3`."
  @type summary :: %{optional(:account) => String.t() | nil, optional(class()) => counts()}

  @typedoc "A decoded message summary."
  @type document :: %{
          waiting: boolean(),
          account: String.t() | nil,
          messages: %{optional(class()) => counts()}
        }

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "The content type of message summaries."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Sets the message summary of an AOR, and notifies the watchers if it has
  changed.
  """
  @spec put(module(), Notifier.aor(), summary()) :: :ok
  def put(service, aor, summary) when is_map(summary) do
    if get(service, aor) == summary do
      :ok
    else
      Notifier.put_item(service, @event, aor, :summary, summary)
      Notifier.notify(service, @event, aor)
    end
  end

  @doc "The message summary of an AOR (empty if it has not been set)."
  @spec get(module(), Notifier.aor()) :: summary()
  def get(service, aor) do
    case Notifier.items(service, @event, aor) do
      [{:summary, summary}] -> summary
      [] -> %{}
    end
  end

  @doc """
  Builds a message summary body.

      iex> Caracola.MessageWaiting.encode(%{account: "sip:alice@example.com", voice: %{new: 2, old: 8, urgent_old: 1}})
      "Messages-Waiting: yes\\r\\nMessage-Account: sip:alice@example.com\\r\\nVoice-Message: 2/8 (0/1)\\r\\n"
      iex> Caracola.MessageWaiting.encode(%{})
      "Messages-Waiting: no\\r\\n"
  """
  @spec encode(summary()) :: String.t()
  def encode(summary) do
    waiting = if waiting?(summary), do: "yes", else: "no"

    account =
      case summary[:account] do
        nil -> []
        account -> ["Message-Account: ", account, "\r\n"]
      end

    lines =
      for {class, name} <- @classes, counts = summary[class], counts != nil do
        [name, ": ", counts(counts), "\r\n"]
      end

    IO.iodata_to_binary(["Messages-Waiting: ", waiting, "\r\n", account, lines])
  end

  defp counts(counts) do
    base = "#{Map.get(counts, :new, 0)}/#{Map.get(counts, :old, 0)}"

    case counts do
      %{urgent_new: _} -> "#{base} (#{counts.urgent_new}/#{Map.get(counts, :urgent_old, 0)})"
      %{urgent_old: _} -> "#{base} (0/#{counts.urgent_old})"
      _ -> base
    end
  end

  defp waiting?(summary) do
    Enum.any?(@classes, fn {class, _} -> Map.get(summary[class] || %{}, :new, 0) > 0 end)
  end

  @doc """
  Parses a message summary body. Message headers after the summary are
  ignored.

      iex> Caracola.MessageWaiting.decode("Messages-Waiting: yes\\r\\nVoice-Message: 2/8 (0/1)\\r\\n")
      {:ok, %{waiting: true, account: nil, messages: %{voice: %{new: 2, old: 8, urgent_new: 0, urgent_old: 1}}}}
      iex> Caracola.MessageWaiting.decode("nothing")
      :error
  """
  @spec decode(binary()) :: {:ok, document()} | :error
  def decode(body) do
    lines =
      body
      |> String.split(["\r\n", "\n"])
      |> Enum.take_while(&(String.trim(&1) != ""))
      |> Enum.flat_map(&header/1)

    case List.keyfind(lines, "messages-waiting", 0) do
      {_, waiting} when waiting in ["yes", "no"] ->
        account =
          case List.keyfind(lines, "message-account", 0) do
            {_, account} -> account
            nil -> nil
          end

        messages =
          for {class, name} <- @classes,
              {_, value} <- [List.keyfind(lines, String.downcase(name), 0)],
              counts = parse_counts(value),
              counts != nil,
              into: %{},
              do: {class, counts}

        {:ok, %{waiting: waiting == "yes", account: account, messages: messages}}

      _ ->
        :error
    end
  end

  defp header(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> [{String.downcase(String.trim(name)), String.trim(value)}]
      _ -> []
    end
  end

  # "2/8 (0/1)" or "2/8"
  defp parse_counts(value) do
    case Regex.run(~r{^(\d+)\s*/\s*(\d+)(?:\s*\(\s*(\d+)\s*/\s*(\d+)\s*\))?$}, value) do
      [_, new, old] ->
        %{new: String.to_integer(new), old: String.to_integer(old)}

      [_, new, old, urgent_new, urgent_old] ->
        %{
          new: String.to_integer(new),
          old: String.to_integer(old),
          urgent_new: String.to_integer(urgent_new),
          urgent_old: String.to_integer(urgent_old)
        }

      nil ->
        nil
    end
  end

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config), do: {:ok, Notifier.add_events(config, [@event])}

  defcb sip_notifier_body("message-summary", aor, _version, service),
    do: {@content_type, encode(get(service, aor))}

  def sip_notifier_body(_event, _aor, _version, _service), do: :cont
end
