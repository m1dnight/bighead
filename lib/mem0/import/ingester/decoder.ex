defmodule Mem0.Ingester.Decoder do
  @moduledoc """
  Decodes strings from the transcripts into plain strings.
  """

  @doc """
  Decode the content of a message into a `t:String`. Will return empty string on
  invalid or empty input.
  """
  @spec decode_contents([map() | String.t()] | String.t()) :: String.t()
  def decode_contents(content) when is_binary(content) do
    decode_contents([content])
  end

  def decode_contents(contents) when is_list(contents) do
    contents
    |> Enum.map(&decode_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec decode_content(map() | String.t()) :: String.t()
  defp decode_content(text) when is_binary(text) do
    String.trim(text)
  end

  defp decode_content(%{"text" => text}) do
    text
    |> String.trim()
  end

  defp decode_content(_) do
    ""
  end
end
