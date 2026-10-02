# The full generation run, in chunks: generate, back up, verify, publish, and again,
# until the calls are made, the corpus runs out, or the dollars do.
#
# Every chunk is exported before anything else happens to it. A generated case cannot be
# bought twice for the same money — the same prompt returns different cases — so no chunk
# is verified, and no next chunk paid for, until the last one is on disk. A backup that
# fails stops the run.
#
# `calls` and `budget_usd` are totals for a label, not for one invocation: every run this
# class opens is tagged with it, and a second invocation with the same label counts what
# the first spent and made. Re-running the same command after a crash, a Ctrl-C or a
# provider outage continues to the same cap instead of paying it again. Generation never
# repeats a statement already cited, and verification only reads cases nobody has judged.
module Questions
  class FullRunner < ApplicationService
    CHUNK_CALLS = 100

    # A provider that fails this many verifications in a row is down, not disagreeing.
    FAILURES_IN_A_ROW = GenerationRunner::FAILURES_IN_A_ROW

    def initialize(calls:, budget_usd:, label: "full", chunk: CHUNK_CALLS, order: "by_specialty",
                   backup_dir: Rails.root.join("tmp/backups"), on_progress: ->(_line) { })
      super()
      @calls = calls
      @budget_usd = budget_usd
      @label = label
      @chunk = chunk
      @order = order
      @backup_dir = backup_dir
      @on_progress = on_progress
    end

    def call
      return failure("Hace falta un tope en dólares mayor que cero") unless budget_usd.to_f.positive?

      unpriced = providers.values.reject(&:priced?)
      return failure("No conozco el precio de #{unpriced.join(", ")}; agrégalo a Llm::Provider") if unpriced.any?

      @backups = []
      stopped = run_chunks
      success(summary(stopped))
    end

    def context_for_logging
      { label: label }
    end

    private

    attr_reader :calls, :budget_usd, :label, :chunk, :order, :backup_dir, :on_progress

    def providers
      @providers ||= { generation: Llm::Provider.for(:generator), verification: Llm::Provider.for(:verifier) }
    end

    # The pending work of an earlier, interrupted invocation is verified first, so a
    # re-run never leaves a paid-for case unverified behind a new chunk.
    def run_chunks
      stopped = verify_and_publish
      return stopped if stopped

      loop do
        return :budget if spent >= budget_usd
        return :calls if calls_made >= calls

        made = generate_chunk
        return :backup_failed unless back_up("chunk-#{chunk_number}")

        stopped = verify_and_publish || made
        return stopped if stopped
      end
    end

    # Returns a stop reason when generation itself ended the run, and nothing otherwise.
    def generate_chunk
      run = open_run(:generation)
      result = GenerationRunner.call(
        run: run, calls: [chunk, calls - calls_made].min, budget_usd: budget_usd - spent_before(run),
        order: order, on_progress: on_progress
      )
      close(run)
      payload = result.payload
      progress(
        "tanda #{chunk_number}: #{payload[:calls]} llamadas, #{payload[:cases]} casos, $#{format(
          "%.4f",
          spent
        )}"
      )

      return :exhausted if payload[:calls].zero?
      # A chunk smaller than GenerationRunner's failure streak can fail whole without
      # tripping it, and a failed call charges nothing, so the call count would never
      # move either: a chunk with no call that worked is the provider, and it ends the run.
      return :generation_failures if payload[:stopped_after_failures] || payload[:failed] == payload[:calls]

      :budget if payload[:stopped_at_budget]
    end

    def verify_and_publish
      stopped = verify
      published = Publisher.call.payload
      progress("publicados #{published[:live]} (+#{published[:published]})")
      stopped
    end

    def verify
      run = open_run(:verification)
      stopped = judge(ClinicalCase.where(verification_verdict: nil).where.not(status: "retired")) do |kase|
        Verifier.call(kase, run: run)
      end
      stopped ||= judge(rationales_pending) { |kase| RationaleVerifier.call(kase, run: run) }
      close(run)
      stopped
    end

    def judge(cases)
      failures = 0
      cases.find_each do |kase|
        return :budget if spent >= budget_usd
        return :verification_failures if failures >= FAILURES_IN_A_ROW

        failures = yield(kase).success? ? 0 : failures + 1
      end
      nil
    end

    # Supported cases whose rationales were never judged: the pilot bank, and any case
    # whose rationale call failed after its verdict was recorded.
    def rationales_pending
      unjudged = AnswerOption.rationale_unjudged.of_originals.select("questions.clinical_case_id")
      ClinicalCase.verdict_supported.where(id: unjudged).where.not(status: "retired")
    end

    def back_up(name)
      path = backup_dir.join("question-bank-#{label}-#{Time.current.strftime("%Y%m%d-%H%M%S")}-#{name}.jsonl.gz")
      result = Exporter.call(path.to_s)
      progress(result.success? ? "respaldo #{path}" : "respaldo fallido: #{result.errors.full_messages.to_sentence}")
      @backups << path.to_s if result.success?
      result.success?
    end

    def open_run(purpose)
      provider = providers.fetch(purpose)
      GenerationRun.create!(
        purpose: purpose.to_s, provider: provider.name, model: provider.model,
        started_at: Time.current, notes: tag
      )
    end

    def close(run)
      run.update!(status: "completed", finished_at: Time.current)
    end

    def tag
      "full_run:#{label}"
    end

    def runs
      GenerationRun.where(notes: tag)
    end

    def spent
      runs.sum(:cost_usd).to_f
    end

    def spent_before(run)
      runs.where.not(id: run.id).sum(:cost_usd).to_f
    end

    def calls_made
      runs.purpose_generation.sum(:calls)
    end

    def chunk_number
      runs.purpose_generation.count
    end

    def progress(line)
      on_progress.call(line)
    end

    def summary(stopped)
      back_up("final") if stopped != :backup_failed
      generation = runs.purpose_generation
      {
        stopped: stopped, calls: calls_made, cost_usd: spent.round(4),
        cases: generation.sum(:cases_created), rejected: generation.sum(:rejections),
        live: ClinicalCase.status_published.count, backups: @backups
      }
    end
  end
end
