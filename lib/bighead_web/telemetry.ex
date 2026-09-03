defmodule BigheadWeb.Telemetry do
  use Supervisor

  import Telemetry.Metrics

  alias Telemetry.Metrics.ConsoleReporter

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ reporters()

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("bighead.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("bighead.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("bighead.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("bighead.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("bighead.repo.query.idle_time",
        unit: {:native, :millisecond},
        description: "The time the connection spent waiting before being checked out for the query"
      ),

      # Bighead Metrics
      #
      # Every span below follows the `:telemetry.span/3` convention:
      # `[:bighead, <domain>, :start | :stop | :exception]`, where `<domain>` is
      # one of `:llm`, `:embedder`, `:ingest`, `:search`. The events themselves
      # are emitted by code written from Phase 3 onward; the definitions live
      # here first so that each phase extends one convention rather than
      # inventing its own.
      #
      # Per the redaction policy in config/config.exs, no measurement or tag on
      # these events may carry a prompt, a completion or a memory's contents.
      # Tags are limited to low-cardinality metadata such as `:model`,
      # `:adapter` and `:operation`.
      summary("bighead.llm.stop.duration",
        tags: [:model],
        unit: {:native, :millisecond},
        description: "Wall time of one LLM call"
      ),
      counter("bighead.llm.exception.duration",
        tags: [:model, :kind],
        description: "LLM calls that raised"
      ),
      sum("bighead.llm.stop.input_tokens",
        tags: [:model],
        description: "Prompt tokens consumed"
      ),
      sum("bighead.llm.stop.output_tokens",
        tags: [:model],
        description: "Completion tokens produced"
      ),
      summary("bighead.embedder.stop.duration",
        tags: [:model],
        unit: {:native, :millisecond},
        description: "Wall time of one embedding call"
      ),
      sum("bighead.embedder.stop.input_count",
        tags: [:model],
        description: "Texts submitted for embedding"
      ),
      # Hook ingress (Phase 4). Not a span: parsing a batch is one traversal
      # with no failure mode of its own, so there is a single event with the
      # counts on it. `drops` in the metadata carries the same total broken out
      # by reason — an aggregate would bury a new entry type under the
      # known-constant majority the type rule rejects on every batch. With no
      # dev LiveView any more, this is the only thing that says a batch landed.
      summary("bighead.ingest.received.duration",
        tags: [:hook_event],
        unit: {:microsecond, :millisecond},
        description: "Wall time of one transcript normalisation"
      ),
      sum("bighead.ingest.received.entries",
        tags: [:hook_event],
        description: "Transcript entries offered by a hook"
      ),
      sum("bighead.ingest.received.messages",
        tags: [:hook_event],
        description: "Entries that became messages"
      ),
      sum("bighead.ingest.received.dropped",
        tags: [:hook_event],
        description: "Entries the normaliser could not use"
      ),
      # Summary refresh (Phase 8). Not a span, for the ingest event's
      # reason: one check, one outcome. The refresh is fire-and-forget off
      # the Stop pulse, which makes this its only failure surface — and the
      # `:fresh`/`:regenerated` ratio per turn is the cadence-versus-cost
      # curve `max_lag` gets retuned against.
      summary("bighead.summarize.refresh.duration",
        tags: [:outcome],
        unit: {:microsecond, :millisecond},
        description: "Wall time of one summary freshness check, by outcome"
      ),
      summary("bighead.ingest.stop.duration",
        unit: {:native, :millisecond},
        description: "Wall time of one ingestion, extraction through update"
      ),
      sum("bighead.ingest.stop.operation_count",
        tags: [:operation],
        description: "Memory operations performed, by ADD/UPDATE/DELETE/NOOP"
      ),
      summary("bighead.search.stop.duration",
        tags: [:channel],
        unit: {:native, :millisecond},
        description: "Wall time of one retrieval, by channel"
      ),
      summary("bighead.search.stop.result_count",
        tags: [:channel],
        description: "Results returned, by channel"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @spec reporters() :: [Supervisor.child_spec() | {module(), term()}]
  defp reporters do
    if Application.get_env(:bighead, :telemetry_console_reporter, false) do
      [{ConsoleReporter, metrics: metrics()}]
    else
      []
    end
  end

  @spec periodic_measurements() :: [{module(), atom(), [term()]}]
  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {BigheadWeb, :count_users, []}
    ]
  end
end
