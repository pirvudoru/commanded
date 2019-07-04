defmodule Commanded.Application.Supervisor do
  @moduledoc false

  use Supervisor

  @doc """
  Retrieves the compile time configuration.
  """
  def compile_config(application, opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    event_store = opts[:event_store]

    unless event_store do
      raise ArgumentError, "missing :event_store option on use Commanded.Application"
    end

    {event_store_adapter, event_store_config} = Keyword.pop(event_store, :adapter)

    unless Code.ensure_compiled?(event_store_adapter) do
      raise ArgumentError,
            "event store adapter #{inspect(event_store_adapter)} was not compiled, " <>
              "ensure it is correct and it is included as a project dependency"
    end

    behaviours =
      for {:behaviour, behaviours} <- event_store_adapter.__info__(:attributes),
          behaviour <- behaviours,
          do: behaviour

    unless Commanded.EventStore in behaviours do
      raise ArgumentError,
            "expected :event_store_adapter option given to Commanded.Application to list Commanded.EventStore as a behaviour"
    end

    event_store = event_store_adapter.event_store(application, event_store_config)

    {otp_app, event_store_adapter, event_store_config, event_store}
  end

  @doc """
  Retrieves the runtime configuration.
  """
  def runtime_config(application, otp_app, opts) do
    config =
      Application.get_env(otp_app, application, [])
      |> Keyword.merge(opts)
      |> Keyword.merge(otp_app: otp_app)

    case application_init(application, config) do
      {:ok, config} -> {:ok, config}
      :ignore -> :ignore
    end
  end

  @doc """
  Starts the application supervisor.
  """
  def start_link(application, otp_app, event_store, opts) do
    sup_opts = if name = Keyword.get(opts, :name, application), do: [name: name], else: []

    Supervisor.start_link(
      __MODULE__,
      {application, otp_app, event_store, opts},
      sup_opts
    )
  end

  def init({application, otp_app, event_store, opts}) do
    case runtime_config(application, otp_app, opts) do
      {:ok, _config} ->
        children =
          event_store.child_spec() ++
            Commanded.Registration.child_spec() ++
            Commanded.PubSub.child_spec() ++
            [
              {Task.Supervisor, name: Commanded.Commands.TaskDispatcher},
              Commanded.Aggregates.Supervisor,
              Commanded.Subscriptions.Registry,
              Commanded.Subscriptions
            ]

        Supervisor.init(children, strategy: :one_for_one)

      :ignore ->
        :ignore
    end
  end

  defp application_init(application, config) do
    if Code.ensure_loaded?(application) and function_exported?(application, :init, 1) do
      application.init(config)
    else
      {:ok, config}
    end
  end
end
