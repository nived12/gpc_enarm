# One generation call: a window of a guideline's recommendations in, clinical cases out.
#
# The steps each live in their own class, so this one reads as the sequence:
# Questions::Prompt writes what the model is asked, Llm::Completion asks it, and
# Questions::CaseBuilder keeps only the questions whose citation checks out.
module Questions
  class CaseGenerator < ApplicationService
    RECOMMENDATIONS_PER_CALL = 8
    MAX_TOKENS = 12_000

    # The real exam is written in Spanish with a small English share, so the bank has to
    # be too. Kept as a fraction of *cases*, not questions, because a case and its
    # questions must be in one language.
    ENGLISH_SHARE = 0.08

    # `recommendations` lets a runner walk a guideline window by window; left out, the
    # call takes the guideline's first `limit` actionable statements.
    def initialize(guideline, run: nil, limit: RECOMMENDATIONS_PER_CALL, recommendations: nil,
                   detail: :focused, locale: "es")
      super()
      @guideline = guideline
      @run = run
      @limit = limit
      @recommendations = recommendations&.to_a
      @detail = detail
      @locale = locale
    end

    def call
      return failure("La guía no tiene recomendaciones accionables") if recommendations.empty?

      completion = Llm::Completion.call(role: :generator, prompt: prompt, max_tokens: MAX_TOKENS)
      return failure(completion.errors) unless completion.success?

      run&.charge!(completion.payload)
      payload = Llm::Completion.json_in(completion.payload[:content])
      return failure("El modelo no devolvió JSON legible") if payload.nil?

      built = CaseBuilder.call(
        payload, guideline: guideline, recommendations: recommendations, run: run, locale: locale
      ).payload
      record(built)

      success(
        cases: built[:cases], rejected: built[:rejected], reasons: built[:reasons],
        tokens: completion.payload[:output_tokens]
      )
    end

    def context_for_logging
      { catalog_key: guideline.catalog_key }
    end

    private

    attr_reader :guideline, :run, :limit, :detail, :locale

    def recommendations
      @recommendations ||= Recommendation.actionable
                                         .where(guideline_sections: { guideline_id: guideline.id })
                                         .order(:id).limit(limit).to_a
    end

    def prompt
      Prompt.new(guideline, recommendations, detail: detail, locale: locale).to_s
    end

    def record(built)
      return if run.nil?

      run.increment!(:cases_created, built[:cases].size)
      run.increment!(:attempts, built[:cases].size + built[:rejected])
      run.increment!(:rejections, built[:rejected])
      run.tally_rejections!(built[:reasons])
    end
  end
end
