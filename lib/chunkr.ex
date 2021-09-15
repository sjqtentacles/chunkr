defmodule Chunkr do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  require Ecto.Query
  alias Chunkr.{Config, Cursor, Opts, Page}

  @doc false
  defmacro __using__(config) do
    quote do
      @default_config Config.new([{:repo, __MODULE__} | unquote(config)])

      def paginate!(queryable, query_name, opts) do
        unquote(__MODULE__).paginate!(queryable, query_name, opts, @default_config)
      end

      def paginate(queryable, query_name, opts) do
        unquote(__MODULE__).paginate(queryable, query_name, opts, @default_config)
      end
    end
  end

  @doc """
  Same as `paginate/4`, but raises an error for invalid input.
  """
  def paginate!(queryable, query_name, opts, config) do
    case paginate(queryable, query_name, opts, config) do
      {:ok, page} -> page
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Paginates an `Ecto.Queryable`.

  Extends the provided `Ecto.Queryable` with the necessary filtering, ordering, and cursor field
  selection for the sake of pagination, then executes the query and returns a `Chunkr.Page` or
  results.

  ## Opts

  * `:first`/`:after` — retrieves the next `n` results _after_ the supplied `:after` cursor. If no
    cursor was specified, retrieves the first `n` results from the full set.
  * `:last`/`:before` — retrieves the last `n` results leading _up to_ the supplied `:before`
    cursor. If no cursor was specified, retrieves the last `n` results from the full set. This
    enables paginating backward from the end of the results toward the beginning.
  """
  def paginate(queryable, query_name, opts, %Config{} = config) do
    case Opts.new(queryable, query_name, opts) do
      {:ok, opts} ->
        extended_rows =
          opts.query
          |> apply_where(opts, config)
          |> apply_order(opts.name, opts.paging_dir, config)
          |> apply_select(opts, config)
          |> apply_limit(opts.limit + 1)
          |> config.repo.all()

        requested_rows = Enum.take(extended_rows, opts.limit)

        rows_to_return =
          case opts.paging_dir do
            :forward -> requested_rows
            :backward -> Enum.reverse(requested_rows)
          end

        {:ok,
         %Page{
           raw_results: rows_to_return,
           has_previous_page: has_previous?(opts, extended_rows, requested_rows),
           has_next_page: has_next?(opts, extended_rows, requested_rows),
           start_cursor: List.first(rows_to_return) |> row_to_cursor(),
           end_cursor: List.last(rows_to_return) |> row_to_cursor(),
           config: config,
           opts: opts
         }}

      {:invalid_opts, message} ->
        {:error, message}
    end
  end

  defp has_previous?(%{paging_dir: :forward} = opts, _, _), do: !!opts.cursor
  defp has_previous?(%{paging_dir: :backward}, rows, requested_rows), do: rows != requested_rows

  defp has_next?(%{paging_dir: :forward}, rows, requested_rows), do: rows != requested_rows
  defp has_next?(%{paging_dir: :backward} = opts, _, _), do: !!opts.cursor

  defp row_to_cursor(nil), do: nil
  defp row_to_cursor({cursor_values, _record}), do: Cursor.encode(cursor_values)

  defp apply_where(query, %{cursor: nil}, _config), do: query

  defp apply_where(query, opts, config) do
    cursor_values = Cursor.decode!(opts.cursor)
    config.queries.beyond_cursor(query, cursor_values, opts.name, opts.paging_dir)
  end

  defp apply_order(query, name, :forward, config) do
    config.queries.apply_order(query, name)
  end

  # TODO: move this
  defp apply_order(query, name, :backward, config) do
    apply_order(query, name, :forward, config)
    |> Ecto.Query.reverse_order()
  end

  defp apply_select(query, opts, config) do
    config.queries.apply_select(query, opts.name)
  end

  # TODO: Move this
  defp apply_limit(query, limit) do
    Ecto.Query.limit(query, ^limit)
  end
end
