# Applies a file written by Questions::BestAvailableExporter. A version is added only
# where its original exists and has none yet; originals, cases and their reviews are never
# touched. A version already there takes the file's verdict, so a later second opinion
# can still reach production.
module Questions
  class BestAvailableImporter < ApplicationService
    def initialize(path)
      super()
      @path = path
    end

    def call
      return failure("No existe #{path}") unless File.exist?(path)

      tally = { created: 0, updated: 0, missing: 0 }
      Zlib::GzipReader.open(path) do |file|
        file.each_line { |line| apply(JSON.parse(line), tally) }
      end

      success(tally)
    end

    private

    attr_reader :path

    def apply(attributes, tally)
      original = Question.originals.joins(:clinical_case).find_by(
        clinical_cases: { export_key: attributes["case_key"] }, position: attributes["position"]
      )
      return tally[:missing] += 1 if original.nil?

      verdict = attributes.slice("best_available_verdict", "best_available_note")
      if (version = original.best_available_variant)
        version.update!(verdict)
        tally[:updated] += 1
      else
        create(original, attributes, verdict)
        tally[:created] += 1
      end
    end

    def create(original, attributes, verdict)
      Question.transaction do
        version = original.create_best_available_variant!(
          clinical_case: original.clinical_case, position: original.position, text: original.text,
          explanation: attributes["explanation"], recommendation: original.recommendation,
          source_quote: original.source_quote, **verdict.symbolize_keys
        )
        attributes["options"].each { |option| version.answer_options.create!(option) }
      end
    end
  end
end
