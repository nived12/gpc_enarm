# What a generation run will cost and yield, worked out from runs already paid for — with
# no request to any provider.
#
# Every ratio comes from this database: tokens and cases per call from the largest
# generation run (the pilot), tokens per verified case from the verification runs, what a
# distractor rationale adds from the rationale runs, and the share of cases that reached
# the bank from the verdicts on record. The one number that is not a ratio is the size of
# the next prompts, which is measured by building them: the windows are the ones
# Questions::WindowPlan would hand the run.
module Questions
  class CostEstimator < ApplicationService
    # Characters per token on this corpus's prompts, measured 2026-09-23 by rebuilding the
    # pilot's prompts and dividing by the tokens each provider billed for them: 193
    # rationale prompts on gemini-3.1-flash-lite (2,241,025 / 524,495) and 197 verifier
    # prompts on deepseek-flash (584,601 / 158,810). A provider not measured takes the
    # lower figure, which errs towards more tokens.
    CHARS_PER_TOKEN = { "gemini" => 4.27, "deepseek" => 3.68 }.freeze

    TARGETS = [3_000, 4_000, 5_000].freeze

    # Every distractor of a question carries a rationale, and the correct option none.
    RATIONALES_PER_QUESTION = Question::OPTION_COUNT - 1

    def initialize(guidelines: Guideline.generatable, calls: nil, order: "by_specialty")
      super()
      @guidelines = guidelines
      @calls = calls
      @order = order
    end

    def call
      return failure("No hay una corrida de generación de referencia") if reference.nil?
      return failure("No hay casos verificados de referencia") if verification_runs.none? || verified.zero?

      success(
        calls: planned_calls, one_pass_calls: windows.size, guidelines: windows.map(&:first).uniq.size,
        measured: measured, per_call: per_call, per_case: per_case, yield: expected_yield,
        costs: costs, targets: targets, pending_rationale_cases: pending_rationale_cases, generation_hours: hours
      )
    end

    private

    attr_reader :guidelines, :order

    def windows
      @windows ||= WindowPlan.new(guidelines, order: order).windows
    end

    def planned_calls
      @calls || windows.size
    end

    def reference
      @reference ||= GenerationRun.purpose_generation.where("cases_created > 0").order(cases_created: :desc).first
    end

    # Runs from before `calls` existed recorded none; every call asks for Prompt::CASES
    # cases and nearly every one returns them, so the count is recovered from the cases.
    def reference_calls
      @reference_calls ||=
        reference.calls.positive? ? reference.calls : (reference.cases_created.to_f / Prompt::CASES).ceil
    end

    def reference_cases
      @reference_cases ||= reference.clinical_cases.includes(:questions).to_a
    end

    def measured
      @measured ||= begin
        questions = reference_cases.sum { |kase| kase.questions.size }
        asking = reference_cases.count { |kase| asks_question?(kase) }
        {
          reference_run: reference.id, reference_calls: reference_calls,
          cases_per_call: (reference.cases_created.to_f / reference_calls).round(3),
          questions_per_case: (questions.to_f / reference_cases.size).round(3),
          rejection_share: (reference.rejections.to_f / (reference.rejections + questions)).round(3),
          stem_asks_question_share: (asking.to_f / reference_cases.size).round(3),
          published_share: (ClinicalCase.publishable.count.to_f / verified).round(3),
          supported_share: (ClinicalCase.verdict_supported.count.to_f / verified).round(3)
        }
      end
    end

    def asks_question?(kase)
      CaseBuilder.asks_question?(kase.stem, kase.questions.map(&:text))
    end

    def verified
      ClinicalCase.where.not(verification_verdict: nil).count
    end

    def verification_runs
      GenerationRun.purpose_verification.where(notes: nil).where("attempts > 0")
    end

    def rationale_runs
      GenerationRun.purpose_rationales.where(notes: nil).where("attempts > 0")
    end

    # The pilot's answers carried no rationales; generation writes them now, so each call
    # also writes what the rationale runs wrote per case.
    def per_call
      @per_call ||= {
        input: (mean_prompt_chars / chars_per_token(Llm::Provider.for(:generator).name)).round,
        output: ((reference.output_tokens.to_f / reference_calls) +
                 (rationale_rate(:output_tokens) * measured[:cases_per_call])).round
      }
    end

    # Mixing the two vignette lengths as GenerationRunner's rotation does.
    def mean_prompt_chars
      return 0 if windows.empty?

      windows.each_with_index.sum do |(guideline, statements), index|
        Prompt.new(guideline, statements, detail: Prompt.detail_for(index)).to_s.length
      end.to_f / windows.size
    end

    # Verification of the answers, as measured, and of the rationales, which no run has
    # paid for yet: a rationale prompt is the rationale writer's prompt with the rationales
    # in it, so its input is that run's, converted from the generator's tokens to the
    # verifier's; and each of a question's three judgements is taken to be as long as the
    # one judgement of its answer.
    def per_case
      @per_case ||= begin
        answers_in = verification_rate(:input_tokens)
        answers_out = verification_rate(:output_tokens)
        ratio = chars_per_token(generator_name_of_rationales) / chars_per_token(Llm::Provider.for(:verifier).name)
        {
          answers_input: answers_in.round, answers_output: answers_out.round,
          rationales_input: (rationale_rate(:input_tokens) * ratio).round,
          rationales_output: (answers_out * RATIONALES_PER_QUESTION).round
        }
      end
    end

    def generator_name_of_rationales
      rationale_runs.pick(:provider) || Llm::Provider.for(:generator).name
    end

    def verification_rate(column)
      verification_runs.sum(column).to_f / verification_runs.sum(:attempts)
    end

    def rationale_rate(column)
      attempts = rationale_runs.sum(:attempts)
      attempts.zero? ? 0 : rationale_runs.sum(column).to_f / attempts
    end

    def chars_per_token(provider)
      CHARS_PER_TOKEN.fetch(provider, CHARS_PER_TOKEN.values.min)
    end

    def cases(calls = planned_calls)
      calls * measured[:cases_per_call] * (1 - measured[:stem_asks_question_share])
    end

    # Rationales still unjudged on cases already supported are verified first by
    # questions:full_run, so they belong in its bill.
    def pending_rationale_cases
      @pending_rationale_cases ||= begin
        unjudged = AnswerOption.rationale_unjudged.of_originals.select("questions.clinical_case_id")
        ClinicalCase.verdict_supported.where(id: unjudged).where.not(status: "retired").count
      end
    end

    def expected_yield
      questions = cases * measured[:questions_per_case]
      {
        cases: cases.round, questions: questions.round,
        published_cases: (cases * measured[:published_share]).round,
        published_questions: (questions * measured[:published_share]).round
      }
    end

    def published_questions_per_call
      measured[:cases_per_call] * (1 - measured[:stem_asks_question_share]) *
        measured[:questions_per_case] * measured[:published_share]
    end

    # Every priced model in either role, so a change of provider is a lookup, not a rerun.
    def costs
      configured = Llm::Provider.all.to_h { |provider| [provider.role, provider.model] }

      Llm::Provider::PRICES.keys.map do |model|
        { model: model, roles: configured.select { |_, name| name == model }.keys,
          generation: generation_cost(model, planned_calls).round(2),
          verification: verification_cost(model, planned_calls).round(2) }
      end
    end

    # What the configured pair would spend to reach each target, pending rationales included.
    def targets
      generator = Llm::Provider.for(:generator).model
      verifier = Llm::Provider.for(:verifier).model

      TARGETS.index_with do |target|
        calls = (target / published_questions_per_call).ceil
        { calls: calls, cost_usd: (generation_cost(generator, calls) + verification_cost(verifier, calls)).round(2) }
      end
    end

    def generation_cost(model, calls)
      calls * price(model, per_call[:input], per_call[:output])
    end

    def verification_cost(model, calls)
      rationale_cases = (cases(calls) * measured[:supported_share]) + pending_rationale_cases
      (cases(calls) * price(model, per_case[:answers_input], per_case[:answers_output])) +
        (rationale_cases * price(model, per_case[:rationales_input], per_case[:rationales_output]))
    end

    # An unpriced model costs nothing here; questions:estimate says so rather than hiding it.
    def price(model, input, output)
      input_price, output_price = Llm::Provider::PRICES.fetch(model, [0, 0])
      ((input * input_price) + (output * output_price)) / 1_000_000.0
    end

    def hours
      return if reference.finished_at.nil? || reference.started_at.nil?

      ((reference.finished_at - reference.started_at) / reference_calls * planned_calls / 3600).round(1)
    end
  end
end
