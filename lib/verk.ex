defmodule Verk do
  @moduledoc """
  Verk is a job processing system that integrates well with Sidekiq jobs

  Each queue will have a pool of workers handled by `poolboy` that will process jobs.

  Verk has a retry mechanism similar to Sidekiq that keeps retrying the jobs with a reasonable backoff.

  It has an API that provides information about the queues
  """
  alias Verk.{Job, Time, Manager}

  @schedule_key "schedule"

  @doc """
  Add a new `queue` with a pool of size `size` of workers
  """
  @spec add_queue(atom, pos_integer) :: Supervisor.on_start_child()
  def add_queue(queue, size \\ 25) when is_atom(queue) and size > 0 do
    Manager.add(queue, size)
  end

  @doc """
  Remove `queue` from the list of queues that are being processed
  """
  @spec remove_queue(atom) :: :ok | {:error, :not_found}
  def remove_queue(queue) when is_atom(queue) do
    Manager.remove(queue)
  end

  defdelegate pause_queue(queue), to: Verk.Manager, as: :pause
  defdelegate resume_queue(queue), to: Verk.Manager, as: :resume

  @doc """
  Enqueues a Job to the specified queue returning the respective job id

  The job must have:
   * a valid `queue`
   * a list of `args` to perform
   * a module to perform (`class`)
   * a valid `jid`

  Optionally a Redix server can be passed which defaults to `Verk.Redis`
  """
  @spec enqueue(%Job{}, GenServer.server()) :: {:ok, binary} | {:error, term}
  def enqueue(job, redis \\ Verk.Redis)
  def enqueue(job = %Job{queue: nil}, _redis), do: {:error, {:missing_queue, job}}
  def enqueue(job = %Job{class: nil}, _redis), do: {:error, {:missing_module, job}}

  def enqueue(job = %Job{args: args}, _redis) when not is_list(args),
    do: {:error, {:missing_args, job}}

  def enqueue(job = %Job{max_retry_count: nil}, redis) do
    job = %Job{job | max_retry_count: Job.default_max_retry_count()}
    enqueue(job, redis)
  end

  def enqueue(job = %Job{max_retry_count: count}, _redis) when not is_integer(count),
    do: {:error, {:invalid_max_retry_count, job}}

  def enqueue(job = %Job{jid: nil}, redis), do: enqueue(%Job{job | jid: generate_jid()}, redis)

  def enqueue(job = %Job{jid: jid, queue: queue}, redis) do
    job = %Job{job | enqueued_at: Time.now() |> DateTime.to_unix()}

    case Redix.command(redis, ["LPUSH", "queue:#{queue}", Job.encode!(job)]) do
      {:ok, _} -> {:ok, jid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Schedules a Job to the specified queue returning the respective job id

  The job must have:
   * a valid `queue`
   * a list of `args` to perform
   * a module to perform (`class`)
   * a valid `jid`

  Optionally a Redix server can be passed which defaults to `Verk.Redis`
  """
  @spec schedule(%Job{}, %DateTime{}, GenServer.server()) :: {:ok, binary} | {:error, term}
  def schedule(job, datetime, redis \\ Verk.Redis)
  def schedule(job = %Job{queue: nil}, %DateTime{}, _redis), do: {:error, {:missing_queue, job}}
  def schedule(job = %Job{class: nil}, %DateTime{}, _redis), do: {:error, {:missing_module, job}}

  def schedule(job = %Job{args: args}, %DateTime{}, _redis) when not is_list(args),
    do: {:error, {:missing_args, job}}

  def schedule(job = %Job{jid: nil}, perform_at = %DateTime{}, redis) do
    schedule(%Job{job | jid: generate_jid()}, perform_at, redis)
  end

  def schedule(job = %Job{jid: jid}, perform_at = %DateTime{}, redis) do
    if Time.after?(Time.now(), perform_at) do
      # past time to do the job
      enqueue(job, redis)
    else
      case Redix.command(redis, [
             "ZADD",
             @schedule_key,
             DateTime.to_unix(perform_at),
             Job.encode!(job)
           ]) do
        {:ok, _} -> {:ok, jid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp generate_jid do
    <<part1::32, part2::32>> = :crypto.strong_rand_bytes(8)
    "#{part1}#{part2}"
  end
end
