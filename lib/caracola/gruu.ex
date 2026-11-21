defmodule Caracola.Gruu do
  @moduledoc """
  Globally Routable User Agent URIs (RFC 5627). Equivalent to NkSIP's
  `nksip_gruu`.

  ```
  defmodule MyRegistrar do
    use Malla.Service,
      plugins: [Caracola.Registrar, Caracola.Gruu],
      sip: [listen: "sip:all:5060"]
  end
  ```

  The plugin adds `gruu` to the Supported header. With it:

    * As UA, Contacts get the `+sip.instance` of the service, and the GRUUs
      received in the responses to REGISTER are available with
      `get_gruu_pub/1` and `get_gruu_temp/1`.
    * As registrar (with `Caracola.Registrar`), registrations with a
      `+sip.instance` from UAs supporting GRUU get a public GRUU (the AOR
      with a `gr` parameter identifying the instance) and a temporary one
      (an encrypted user with `gr`), in the `pub-gruu` and `temp-gruu`
      Contact parameters. A new temporary GRUU is generated in each
      registration; all of them are invalidated when the Call-ID changes.
      `registrar_find/2` finds the contacts of a URI, which can be a GRUU.
  """

  use Malla.Plugin, plugin_deps: [Caracola]

  alias Caracola.{Message, Registrar, URI, Util}
  alias Caracola.Registrar.Contact

  ## ===================================================================
  ## API
  ## ===================================================================

  @doc "The public GRUU received in the last registration."
  @spec get_gruu_pub(module()) :: {:ok, URI.t()} | :undefined
  def get_gruu_pub(service), do: get(service, :pub)

  @doc "The temporary GRUU received in the last registration."
  @spec get_gruu_temp(module()) :: {:ok, URI.t()} | :undefined
  def get_gruu_temp(service), do: get(service, :temp)

  defp get(service, class) do
    case :persistent_term.get({__MODULE__, service, class}, nil) do
      nil -> :undefined
      uri -> {:ok, uri}
    end
  end

  @doc """
  Returns the registered contacts of a URI: for a public GRUU, those of its
  instance; for a temporary GRUU, those of its instance if it is still
  valid; otherwise, those of the AOR (see `Caracola.Registrar.find/2`).
  """
  @spec registrar_find(module(), URI.t()) :: [URI.t()]
  def registrar_find(service, %URI{} = uri) do
    case URI.get_param(uri, "gr") do
      {:ok, nil} ->
        find_temp(service, uri)

      {:ok, instance} ->
        find(service, aor(uri), &(&1[:gruu_instance] == instance))

      :error ->
        Registrar.find(service, uri)
    end
  end

  defp find_temp(service, uri) do
    case decrypt(uri.user) do
      {:ok, {aor, instance, pos}} ->
        find(service, aor, fn meta ->
          meta[:gruu_instance] == instance and Map.get(meta, :gruu_temp_min, 0) <= pos
        end)

      :error ->
        Registrar.find(service, uri)
    end
  end

  defp find(service, aor, fun) do
    for %Contact{meta: meta} = reg <- Registrar.get_info(service, aor),
        fun.(meta),
        do: Registrar.make_contact(reg)
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  @doc false
  def enabled?(config), do: "gruu" in (config[:supported] || [])

  @doc false
  # A UA stores the GRUUs of its contact in a 2xx response to REGISTER
  def uac_response(%Message{class: {:resp, code, _}, cseq: {_, :register}} = resp, config)
      when code in 200..299 do
    instance = ~s("#{config[:instance_id]}")

    resp.contacts
    |> Enum.filter(&(URI.get_ext_param(&1, "+sip.instance") == {:ok, instance}))
    |> Enum.each(fn contact ->
      for {class, param} <- [pub: "pub-gruu", temp: "temp-gruu"],
          {:ok, value} when is_binary(value) <- [URI.get_ext_param(contact, param)],
          {:ok, uri} <- [URI.parse_one(String.trim(value, "\""))],
          do: :persistent_term.put({__MODULE__, resp.service, class}, uri)
    end)
  end

  def uac_response(_resp, _config), do: :ok

  @doc false
  # A Contact can not be a temporary GRUU of the AOR being registered
  def check_contact(%URI{} = contact, aor) do
    with {:ok, nil} <- URI.get_param(contact, "gr"),
         {:ok, {^aor, _, _}} <- decrypt(contact.user) do
      throw({:reply, {:forbidden, "Invalid Contact"}})
    end

    :ok
  end

  @doc false
  # Adds the GRUUs to a registered contact with an instance. `base` is the
  # previous registration of the same contact.
  def update_reg(%Contact{contact: contact, meta: meta} = reg, base, %Message{} = req, aor) do
    next = Map.get(meta, :gruu_temp_next, 0)

    # A new Call-ID invalidates the temporary GRUUs
    meta =
      if base && base.call_id != req.call_id,
        do: Map.put(meta, :gruu_temp_min, next),
        else: meta

    case URI.get_ext_param(contact, "+sip.instance") do
      {:ok, value} when is_binary(value) ->
        if contact.scheme != :sip, do: throw({:reply, {:forbidden, "Invalid Contact"}})
        instance = Util.hash(value)
        {scheme, user, domain} = aor
        pub = %URI{scheme: scheme, user: user, domain: domain, params: [{"gr", instance}]}

        temp = %URI{
          scheme: scheme,
          user: encrypt({aor, instance, next}),
          domain: domain,
          params: [{"gr", nil}]
        }

        ext =
          contact.ext_params ++
            [{"pub-gruu", quote_uri(pub)}, {"temp-gruu", quote_uri(temp)}]

        meta = Map.merge(meta, %{gruu_instance: instance, gruu_temp_next: next + 1})
        %{reg | contact: %{contact | ext_params: ext}, meta: meta}

      _ ->
        %{reg | meta: meta}
    end
  end

  defp quote_uri(uri), do: ~s("#{IO.iodata_to_binary(URI.encode(uri))}")

  defp aor(%URI{scheme: scheme, user: user, domain: domain}), do: {scheme, user, domain}

  # Temporary GRUUs carry the AOR, instance and position, encrypted
  defp encrypt(term) do
    iv = :crypto.strong_rand_bytes(16)
    data = :crypto.crypto_one_time(:aes_128_cfb128, key(), iv, :erlang.term_to_binary(term), true)
    Base.url_encode64(iv <> data, padding: false)
  end

  defp decrypt(user) when is_binary(user) do
    case Base.url_decode64(user, padding: false) do
      {:ok, <<iv::binary-16, data::binary>>} ->
        bin = :crypto.crypto_one_time(:aes_128_cfb128, key(), iv, data, false)
        {_aor, _instance, _pos} = term = :erlang.binary_to_term(bin, [:safe])
        {:ok, term}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp decrypt(_user), do: :error

  defp key, do: binary_part(:crypto.hash(:sha256, Util.global_id()), 0, 16)

  ## ===================================================================
  ## Plugin
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config),
    do: {:ok, Caracola.Config.add_values(config, :supported, ["gruu"])}
end
