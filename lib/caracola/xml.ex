defmodule Caracola.XML do
  @moduledoc false
  # Minimal XML support for the bodies of event packages (PIDF,
  # dialog-info): parsing into `{name, attrs, children}` trees, with local
  # names (without namespace prefixes), and escaping. It uses the SAX parser
  # of xmerl, which does not create atoms; documents with a DTD are rejected
  # (no entity expansion).

  @type element :: {String.t(), %{String.t() => String.t()}, [element() | String.t()]}

  @spec parse(binary()) :: {:ok, element()} | :error
  def parse(xml) when is_binary(xml) do
    if String.contains?(xml, "<!DOCTYPE") do
      :error
    else
      opts = [event_fun: &event/3, event_state: [{nil, %{}, []}], external_entities: :none]

      case :xmerl_sax_parser.stream(xml, opts) do
        {:ok, [{nil, _, [root]}], _rest} -> {:ok, root}
        _ -> :error
      end
    end
  catch
    _, _ -> :error
  end

  defp event({:startElement, _uri, name, _qname, attrs}, _loc, stack) do
    attrs = Map.new(attrs, fn {_uri, _prefix, attr, value} -> {str(attr), str(value)} end)
    [{str(name), attrs, []} | stack]
  end

  defp event({:endElement, _uri, _name, _qname}, _loc, [{name, attrs, children}, parent | rest]) do
    {pname, pattrs, pchildren} = parent
    [{pname, pattrs, [{name, attrs, Enum.reverse(children)} | pchildren]} | rest]
  end

  defp event({:characters, chars}, _loc, [{name, attrs, children} | rest]),
    do: [{name, attrs, [str(chars) | children]} | rest]

  defp event(_event, _loc, stack), do: stack

  defp str(chars), do: List.to_string(chars)

  @doc "The child elements with a name."
  @spec children(element(), String.t()) :: [element()]
  def children({_, _, children}, name), do: for({^name, _, _} = child <- children, do: child)

  @doc "The first child element with a name, or `nil`."
  @spec child(element() | nil, String.t()) :: element() | nil
  def child(nil, _name), do: nil
  def child(element, name), do: element |> children(name) |> List.first()

  @doc "The text of an element (trimmed), `nil` if it is `nil` or empty."
  @spec text(element() | nil) :: String.t() | nil
  def text(nil), do: nil

  def text({_, _, children}) do
    case children |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  @doc "An attribute of an element."
  @spec attr(element() | nil, String.t()) :: String.t() | nil
  def attr(nil, _name), do: nil
  def attr({_, attrs, _}, name), do: Map.get(attrs, name)

  @doc "Escapes text or an attribute value."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    for <<char <- text>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?" -> "&quot;"
        ?' -> "&apos;"
        char -> <<char>>
      end
    end
  end

  @doc "An element with optional text, or `\"\"` if the text is `nil`."
  @spec tag(String.t(), String.t() | nil) :: String.t()
  def tag(_name, nil), do: ""
  def tag(name, text), do: "<#{name}>#{escape(text)}</#{name}>"
end
