# Writes the generated question bank to one portable file.
#
# The opposite policy to Gpc::CorpusExporter, for the opposite reason. Scraped text can
# always be fetched again, so the corpus file carries only what is expensive to obtain and
# rebuilds the rest. A generated case cannot be obtained again at any price: the same
# prompt against the same model returns different wording and different distractors. So
# everything is carried here, and this file is the only backup the one part of the app that
# costs money will ever have.
#
# Nothing is referenced by row id. A case names its guideline by catalog_key and its topic,
# specialty and setting by slug, and a question names its recommendation by the path that
# identifies it in any database: the guideline, the section inside it, and the position
# inside that section.
module Questions
  class Exporter < ApplicationService
    RUN_ATTRIBUTES = %w[
      export_key purpose provider model status input_tokens output_tokens cost_usd
      cases_created attempts rejections notes started_at finished_at calls rejection_reasons
    ].freeze

    CASE_ATTRIBUTES = %w[
      export_key stem locale difficulty status source
      verification_verdict verification_notes verified_at
    ].freeze

    QUESTION_ATTRIBUTES = %w[position text explanation source_quote].freeze
    OPTION_ATTRIBUTES = %w[position text correct rationale rationale_verdict rationale_note].freeze

    BATCH_SIZE = 50

    def initialize(path)
      super()
      @path = path
    end

    def call
      counts = Hash.new(0)

      FileUtils.mkdir_p(File.dirname(path))
      Zlib::GzipWriter.open(path) do |file|
        write_runs(file, counts)
        write_cases(file, counts)
      end

      success(path: path, bytes: File.size(path), **counts)
    end

    private

    attr_reader :path

    # Runs are written before the cases that point at them, so a reader never meets a
    # reference it cannot yet resolve.
    def write_runs(file, counts)
      GenerationRun.order(:id).find_each(batch_size: BATCH_SIZE) do |run|
        file.puts(line("run", run.slice(*RUN_ATTRIBUTES)))
        counts[:runs] += 1
      end
    end

    def write_cases(file, counts)
      cases.find_each(batch_size: BATCH_SIZE) do |kase|
        file.puts(line("case", case_payload(kase)))
        counts[:cases] += 1
        counts[:questions] += kase.questions.size
      end
    end

    def cases
      ClinicalCase.order(:id).includes(
        :generation_run, :guideline, :topic, :specialty, :setting,
        { clinical_image: { guideline_section: :guideline } },
        questions: [
          :answer_options, { best_available_variant: :answer_options },
          { recommendation: { guideline_section: :guideline } }
        ]
      )
    end

    # A case travels whole — its questions and their options nested inside it — so that a
    # case is written or not written, never half of one.
    def case_payload(kase)
      kase.slice(*CASE_ATTRIBUTES).merge(
        "run_key" => kase.generation_run&.export_key,
        "catalog_key" => kase.guideline&.catalog_key,
        "topic_slug" => kase.topic&.slug,
        "specialty_slug" => kase.specialty&.slug,
        "setting_slug" => kase.setting&.slug,
        "image" => figure_payload(kase.clinical_image),
        "questions" => kase.questions.map { |question| question_payload(question) }
      )
    end

    # Only the reference. The figure rows themselves are rebuilt on the far side from
    # section text it already has, the same way recommendations are — the bytes are free
    # to fetch again, so there is no reason to carry a megabyte of them.
    def figure_payload(image)
      return if image.nil?

      section = image.guideline_section
      {
        "catalog_key" => section.guideline.catalog_key,
        "section" => section.external_id,
        "position" => image.position
      }
    end

    def question_payload(question)
      payload = question.slice(*QUESTION_ATTRIBUTES).merge(
        "recommendation" => recommendation_payload(question.recommendation),
        "options" => options_payload(question)
      )
      variant = question.best_available_variant
      variant ? payload.merge("best_available" => best_available_payload(variant)) : payload
    end

    def options_payload(question)
      question.answer_options.map { |option| option.slice(*OPTION_ATTRIBUTES) }
    end

    # Modo ENARM's version travels inside its original, which it shares a case, a
    # citation and a position with; only what differs is written.
    def best_available_payload(variant)
      variant.slice(*BestAvailableExporter::ATTRIBUTES).merge("options" => options_payload(variant))
    end

    def recommendation_payload(recommendation)
      return if recommendation.nil?

      section = recommendation.guideline_section
      {
        "catalog_key" => section.guideline.catalog_key,
        "section" => section.external_id,
        "position" => recommendation.position
      }
    end

    def line(record, attributes)
      attributes.merge("record" => record).to_json
    end
  end
end
