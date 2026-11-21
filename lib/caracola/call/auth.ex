defmodule Caracola.Call.Auth do
  @moduledoc false
  # Digest authentication in the call process (server side) and generation
  # of credentials for challenged requests (client side). Port of the
  # stateful part of NkSIP's nksip_auth, nksip_call_lib (authorized dialog
  # origins) and the nksip_uac_auto_auth plugin.
  #
  # Nonces are stored, with the address they were sent to and an expiration
  # time, in an ETS table owned by Caracola.Call.Auth.Nonces.

  alias Caracola.{Call, Digest, Message, Util}

  @nonces :caracola_nonces

  ## ===================================================================
  ## Server
  ## ===================================================================

  @doc false
  # Challenges with a new nonce, valid for the address of the request: one
  # for each accepted algorithm, the strongest first (RFC 8760 §2.4)
  def challenges(%Message{} = req, realm, %Call{} = call) do
    nonce = Util.uid()
    expires = System.monotonic_time(:second) + (call.config[:nonce_timeout] || 30)
    :ets.insert(@nonces, {{call.service, call.call_id, nonce}, remote_ip(req), expires})
    opaque = Util.hash(call.service)

    for algorithm <- Digest.by_strength(algorithms(call)),
        do: Digest.challenge(realm || req.from.domain, nonce, opaque, algorithm)
  end

  defp algorithms(call), do: call.config[:digest_algorithms] || [:md5]

  @doc false
  # The authorization list of a request for sip_authorize: `:dialog` if it
  # comes from an authorized origin of its dialog, and the result of the
  # digest credentials of each realm (`true` > `:invalid` > `false`)
  def authorize_data(%Message{} = req, %Call{} = call) do
    dialog = if MapSet.member?(call.auths, {req.dialog_id, origin(req)}), do: [:dialog], else: []

    digest =
      for {name, value} <- req.headers,
          name in ["authorization", "proxy-authorization"],
          {:ok, params} <- [Digest.parse(value)],
          reduce: %{} do
        acc ->
          realm = Map.get(params, :realm, "")
          result = check(params, req, call)
          Map.update(acc, realm, result, &if(rank(result) > rank(&1), do: result, else: &1))
      end

    list = dialog ++ for({realm, result} <- digest, do: {{:digest, realm}, result})

    case Call.callback(call, :sip_authorize_data, [list, req, call]) do
      list when is_list(list) -> list
      _ -> list
    end
  end

  defp rank(true), do: 3
  defp rank(:invalid), do: 2
  defp rank(false), do: 1

  defp check(params, req, call) do
    user = Map.get(params, :username, "")
    realm = Map.get(params, :realm, "")

    case Call.callback(call, :sip_get_user_pass, [user, realm, req, call]) do
      true ->
        true

      pass when is_binary(pass) or (is_tuple(pass) and elem(pass, 0) == :ha1) ->
        verify(params, pass, req, call)

      _ ->
        false
    end
  end

  # The nonce must have been sent by us, in this call, to the same address
  # (except for ACK, which can come from another one), and not be expired
  defp verify(params, pass, %Message{class: {:req, method}} = req, call) do
    key = {call.service, call.call_id, Map.get(params, :nonce)}
    now = System.monotonic_time(:second)
    remote = remote_ip(req)

    case :ets.lookup(@nonces, key) do
      [{_, ip, expires}] when expires >= now and (method == :ack or ip == remote) ->
        Digest.verify(params, method, pass, algorithms(call))

      _ ->
        :invalid
    end
  end

  @doc false
  # Remembers the origin of a message as authorized for its dialog
  def update(%Call{} = call, %Message{dialog_id: id, port: %{}} = msg) when is_binary(id),
    do: %{call | auths: MapSet.put(call.auths, {id, origin(msg)})}

  def update(call, _msg), do: call

  @doc false
  def authorized(%Call{auths: auths}, dialog_id),
    do: for({^dialog_id, origin} <- auths, do: origin)

  @doc false
  def clear(%Call{auths: auths} = call, dialog_id),
    do: %{call | auths: MapSet.reject(auths, &match?({^dialog_id, _}, &1))}

  defp origin(%Message{port: %{} = port}), do: {port.transport, port.remote_ip, port.remote_port}
  defp origin(%Message{}), do: nil

  defp remote_ip(%Message{port: %{remote_ip: ip}}), do: ip
  defp remote_ip(%Message{}), do: nil

  ## ===================================================================
  ## Client
  ## ===================================================================

  @doc false
  # Adds credentials to a request challenged by a 401 or 407 response,
  # using the passwords of the request options and the configuration: for
  # each realm, to its challenge with the strongest supported algorithm
  # (RFC 8760 §2.4). Fails if no challenge can be answered, or all of them
  # were already answered (same nonce).
  def credentials(%Message{} = req, %Message{} = resp, passwords) do
    answered = nonces(req)

    resp
    |> challenges()
    |> Enum.reject(fn {_name, params} -> Map.get(params, :nonce) in answered end)
    |> Enum.group_by(fn {_name, params} -> Map.get(params, :realm, "") end)
    |> Enum.flat_map(fn {realm, challenges} -> answer(realm, challenges, req, passwords) end)
    |> case do
      [] ->
        :error

      headers ->
        {:ok,
         Enum.reduce(headers, req, fn {name, value}, req ->
           {:ok, req} = Message.update_header(req, :add, name, value)
           req
         end)}
    end
  end

  defp answer(realm, challenges, %Message{class: {:req, method}} = req, passwords) do
    case find_password(passwords, realm) do
      {:ok, password} ->
        opts = [method: method, uri: req.ruri, user: req.from.user || "", password: password]

        challenges
        |> Enum.sort_by(&Digest.strength(Map.get(elem(&1, 1), :algorithm, :md5)), :desc)
        |> Enum.find_value([], &authorization(&1, opts))

      :error ->
        []
    end
  end

  defp authorization({name, params}, opts) do
    case Digest.authorization(params, opts) do
      {:ok, value} when name == "www-authenticate" -> [{"authorization", value}]
      {:ok, value} -> [{"proxy-authorization", value}]
      :error -> nil
    end
  end

  defp challenges(%Message{headers: headers}) do
    for {name, value} <- headers,
        name in ["www-authenticate", "proxy-authenticate"],
        {:ok, %{scheme: :digest} = params} <- [Digest.parse(value)],
        do: {name, params}
  end

  defp nonces(%Message{headers: headers}) do
    for {name, value} <- headers,
        name in ["authorization", "proxy-authorization"],
        {:ok, params} <- [Digest.parse(value)],
        do: Map.get(params, :nonce)
  end

  # The password of the realm, or one for any realm
  defp find_password(passwords, realm) do
    case List.keyfind(passwords, realm, 0) || List.keyfind(passwords, "", 0) do
      {_, password} -> {:ok, password}
      nil -> :error
    end
  end

  @doc false
  # Normalizes passwords: a password (for any realm), an HA1 (`{:ha1, hex}`
  # or `{:ha1, algorithm, hex}`), `{realm, password}` or a list of them
  def passwords(nil), do: []
  def passwords(list) when is_list(list), do: Enum.flat_map(list, &passwords/1)
  def passwords(pass) when is_binary(pass), do: [{"", pass}]
  def passwords({:ha1, _} = pass), do: [{"", pass}]
  def passwords({:ha1, _, _} = pass), do: [{"", pass}]
  def passwords({realm, pass}) when is_binary(realm), do: [{realm, pass}]
  def passwords(_other), do: []
end

defmodule Caracola.Call.Auth.Nonces do
  @moduledoc false
  # Owner of the nonces table, removing expired nonces periodically

  use GenServer

  @nonces :caracola_nonces
  @sweep 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@nonces, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    :ets.select_delete(@nonces, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
