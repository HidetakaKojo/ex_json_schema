defmodule ExJsonSchema.Schema do
  defmodule UnsupportedSchemaVersionError do
    defexception message: "unsupported schema version, only draft 4 is supported"
  end

  defmodule InvalidSchemaError do
    defexception message: "invalid schema"
  end

  alias ExJsonSchema.Schema.Meta
  alias ExJsonSchema.Schema.Root

  @type resolved :: %{String.t => ExJsonSchema.json_value | (Root.t -> {Root.t, resolved})}

  @current_draft_schema_url "http://json-schema.org/schema"
  @draft4_schema_url "http://json-schema.org/draft-04/schema"

  @spec resolve(Root.t) :: Root.t | no_return
  def resolve(root = %Root{}), do: resolve_root(root)

  @spec resolve(ExJsonSchema.json) :: Root.t | no_return
  def resolve(schema = %{}), do: resolve_root(%Root{schema: schema})

  @spec resolve(any) :: any
  def resolve(non_schema), do: non_schema

  defp resolve_root(root) do
    assert_supported_schema_version(Map.get(root.schema, "$schema", @current_draft_schema_url <> "#"))
    assert_valid_schema(root.schema)
    {root, schema} = resolve_with_root(root, root.schema)
    %{root | schema: schema}
  end

  defp assert_supported_schema_version(version) do
    unless supported_schema_version?(version), do: raise UnsupportedSchemaVersionError
  end

  defp assert_valid_schema(schema) do
    unless meta?(schema) do
      case ExJsonSchema.Validator.validate(resolve(Meta.draft4), schema) do
        {:error, errors} ->
          raise InvalidSchemaError, message: "schema did not pass validation against its meta-schema: #{inspect(errors)}"
        _ ->
      end
    end
  end

  defp supported_schema_version?(version) do
    case version do
      @current_draft_schema_url <> _ -> true
      @draft4_schema_url <> _ -> true
      _ -> false
    end
  end

  defp resolve_with_root(root, schema, scope \\ "")

  defp resolve_with_root(root, schema = %{"id" => id}, scope) when is_binary(id) do
    do_resolve(root, schema, scope <> id)
  end

  defp resolve_with_root(root, schema = %{}, scope) do
    do_resolve(root, schema, scope)
  end

  defp resolve_with_root(root, non_schema, _scope) do
    {root, non_schema}
  end

  defp do_resolve(root, schema, scope) do
    {root, schema} = Enum.reduce schema, {root, %{}}, fn (property, {root, schema}) ->
      {root, {k, v}} = resolve_property(root, property, scope)
      {root, Map.put(schema, k, v)}
    end
    {root, schema |> sanitize_properties |> sanitize_items}
  end

  defp resolve_property(root, {key, value}, scope) when is_map(value) do
    {root, resolved} = resolve_with_root(root, value, scope)
    {root, {key, resolved}}
  end

  defp resolve_property(root, {key, values}, scope) when is_list(values) do
    {root, values} = Enum.reduce values, {root, []}, fn (value, {root, values}) ->
      {root, resolved} = resolve_with_root(root, value, scope)
      {root, [resolved | values]}
    end
    {root, {key, Enum.reverse(values)}}
  end

  defp resolve_property(root, {"$ref", ref}, scope) do
    ref = String.replace(scope <> ref, "##", "#")
    {root, ref} = resolve_ref(root, ref)
    {root, {"$ref", ref}}
  end

  defp resolve_property(root, tuple, _), do: {root, tuple}

  defp resolve_ref(root, "#") do
    {root, &root_schema_resolver/1}
  end

  defp resolve_ref(root, ref) do
    [url | fragments] = String.split(ref, "#")

    resolver = relative_resolver = case fragments do
      [fragment = "/" <> _] -> relative_ref_resolver(fragment)
      _ -> &root_schema_resolver/1
    end

    if url != "" do
      root = resolve_and_cache_remote_schema(root, url)
      resolver = url_with_relative_ref_resolver(url, relative_resolver)
    end

    assert_reference_valid(resolver, root, ref)

    {root, resolver}
  end

  defp relative_ref_resolver(ref) do
    ["" | keys] = unescaped_ref_segments(ref)
    keys = Enum.map keys, fn key ->
      case key =~ ~r/^\d+$/ do
        true ->
          index = String.to_integer(key)
          fn :get, data, _ -> Enum.at(data, index) end
        false -> key
      end
    end
    fn root -> {root, get_in(root.schema, keys)} end
  end

  defp url_with_relative_ref_resolver(url, relative_ref_resolver) do
    fn root ->
      remote_schema = root.refs[url]
      relative_ref_resolver.(%{root | schema: remote_schema})
    end
  end

  defp root_schema_resolver(root) do
    {root, root.schema}
  end

  defp resolve_and_cache_remote_schema(root, url) do
    unless root.refs[url] do
      root = fetch_and_resolve_remote_schema(root, url)
    end
    root
  end

  defp fetch_and_resolve_remote_schema(root, url) when url == @current_draft_schema_url or url == @draft4_schema_url do
    resolve_remote_schema(root, url, Meta.draft4)
  end

  defp fetch_and_resolve_remote_schema(root, url) do
    resolve_remote_schema(root, url, remote_schema_resolver.(url))
  end

  defp resolve_remote_schema(root, url, remote_schema) do
    root = root_with_ref(root, url, remote_schema)
    resolved_root = resolve_root(%{root | schema: remote_schema})
    root_with_ref(root, url, resolved_root.schema)
  end

  defp root_with_ref(root, url, ref) do
    %{root | refs: Map.put(root.refs, url, ref)}
  end

  defp remote_schema_resolver do
    Application.get_env(:ex_json_schema, :remote_schema_resolver)
  end

  defp assert_reference_valid(resolver, root, ref) do
    case resolver.(root) do
      {_, nil} -> raise InvalidSchemaError, message: "reference #{ref} could not be resolved"
      _ ->
    end
  end

  defp sanitize_properties(schema) do
    if Enum.any?(~w(patternProperties additionalProperties), &Map.has_key?(schema, &1)) and not Map.has_key?(schema, "properties") do
      schema = Map.put(schema, "properties", %{})
    end
    schema
  end

  defp sanitize_items(schema) do
    if Map.has_key?(schema, "items") and not Map.has_key?(schema, "additionalItems") do
      schema = Map.put(schema, "additionalItems", true)
    end
    schema
  end

  defp unescaped_ref_segments(ref) do
    ref
    |> String.split("/")
    |> Enum.map fn segment ->
      segment
      |> String.replace("~0", "~")
      |> String.replace("~1", "/")
      |> URI.decode
    end
  end

  defp meta?(schema) do
    String.starts_with?(Map.get(schema, "id", ""), @draft4_schema_url)
  end
end
