# Loads a file written by Questions::Exporter into this environment's database.
#
# Idempotent on `export_key`, so a file can be replayed over a database that already holds
# part of it without paying for those cases twice. A replay overwrites what it finds —
# status included — which is right while cases are reviewed where they were generated.
# Once review happens in production, `only_new:` leaves every case the database already
# has exactly as it is, questions and all, and brings in only the ones it lacks.
#
# Every reference in the file is resolved against what this database actually has, and a
# reference that does not resolve fails the import. That is deliberate: a case whose
# guideline is missing, or whose question lost its recommendation, would import looking
# complete while citing nothing — which is the one failure this product cannot afford,
# because the citation is what makes a generated question trustworthy at all.
module Questions
  class Importer < ApplicationService
    # Raised and caught inside this class only, to abandon one case without abandoning
    # the file. Nothing escapes; the caller still gets a Response.
    MissingReference = Class.new(StandardError)

    def initialize(path, only_new: false)
      super()
      @path = path
      @only_new = only_new
    end

    def call
      return failure("No existe el archivo #{path}") unless File.exist?(path)

      counts = Hash.new(0)
      Zlib::GzipReader.open(path) { |file| file.each_line { |line| import(line, counts) } }
      # The counts travel with a failure too: refusals are named one by one, and the
      # caller still has to say how much of the file did land.
      return failure(payload: counts) if has_errors?

      success(counts)
    rescue Zlib::GzipFile::Error => e
      failure("El archivo no se pudo descomprimir: #{e.message}")
    end

    private

    attr_reader :path, :only_new

    def import(line, counts)
      attributes = ActiveSupport::JSON.decode(line)

      case attributes.delete("record")
      when "run" then import_run(attributes, counts)
      when "case" then import_case(attributes, counts)
      else failure("Registro desconocido en el archivo")
      end
    rescue JSON::ParserError
      failure("El archivo tiene una línea que no es JSON")
    end

    def import_run(attributes, counts)
      run = GenerationRun.find_or_initialize_by(export_key: attributes["export_key"])
      counts[run.new_record? ? :runs_created : :runs_updated] += 1
      run.update!(attributes)
    end

    def import_case(attributes, counts)
      questions = attributes.delete("questions")
      figure = attributes.delete("image")
      references = attributes.extract!("run_key", "catalog_key", "topic_slug", "specialty_slug", "setting_slug")

      if only_new && (existing = ClinicalCase.find_by(export_key: attributes["export_key"]))
        counts[:cases_skipped] += 1
        counts[:second_opinions_synced] += 1 if sync_second_opinion(existing, attributes, questions)
        return
      end

      # Tallied apart and added only once the case commits, so a refused case is counted
      # as refused and not also as created.
      tally = Hash.new(0)
      ClinicalCase.transaction do
        kase = ClinicalCase.find_or_initialize_by(export_key: attributes["export_key"])
        tally[kase.new_record? ? :cases_created : :cases_updated] += 1
        kase.update!(attributes.merge(resolve(references), clinical_image: image_for(figure)))
        Array(questions).each { |question| import_question(kase, question, tally) }
      end
      counts.merge!(tally) { |_key, total, added| total + added }
    rescue MissingReference => e
      refuse(counts, "El caso #{attributes["export_key"]} cita #{e.message}")
    rescue ActiveRecord::RecordInvalid => e
      refuse(
        counts,
        "El caso #{attributes["export_key"]} no se pudo guardar: #{e.record.errors.full_messages.to_sentence}"
      )
    end

    # A case production already holds keeps its text, its status and whatever a person
    # decided there. The second opinion is a model's, rerun here as the verifier learns
    # (questions:recheck), so it moves on: the case's verdict and notes, and each
    # rationale's verdict — only while production's rationale is the text that was judged.
    # Only a later judgement moves the case's verdict, so a file exported from a database
    # that is behind, or where the case was never judged, cannot roll production back. It
    # may take a live case off the bank (ClinicalCase#status_after_verdict); a supported
    # draft waits for the next questions:publish. True when anything changed.
    def sync_second_opinion(kase, attributes, questions)
      if newer_opinion?(kase, attributes["verified_at"])
        verdict = attributes.slice("verification_verdict", "verification_notes", "verified_at")
        kase.assign_attributes(verdict.merge(status: kase.status_after_verdict(verdict["verification_verdict"])))
      end
      options = rationale_verdicts(kase, questions)
      return false unless kase.changed? || options.any?(&:changed?)

      ClinicalCase.transaction do
        kase.save!
        options.each(&:save!)
      end
      true
    end

    def newer_opinion?(kase, judged_at)
      return false if judged_at.blank?

      kase.verified_at.nil? || Time.zone.parse(judged_at.to_s) > kase.verified_at
    end

    # Options carry no judging time, so a file only brings a verdict it has, never an
    # empty one, and only for the rationale text it judged.
    def rationale_verdicts(kase, questions)
      Array(questions).flat_map do |question_attributes|
        question = kase.questions.find { |candidate| candidate.position == question_attributes["position"] }
        Array(question_attributes["options"]).filter_map do |attributes|
          option = question&.answer_options&.find { |candidate| candidate.position == attributes["position"] }
          next if option.nil? || option.rationale != attributes["rationale"] || attributes["rationale_verdict"].nil?

          option.tap { |judged| judged.assign_attributes(attributes.slice("rationale_verdict", "rationale_note")) }
        end
      end
    end

    def refuse(counts, message)
      counts[:cases_refused] += 1
      failure(message)
    end

    def resolve(references)
      {
        generation_run: find_by!(GenerationRun, :export_key, references["run_key"], "la corrida"),
        guideline: find_by!(Guideline, :catalog_key, references["catalog_key"], "la guía"),
        topic: find_by!(Topic, :slug, references["topic_slug"], "el tema"),
        specialty: find_by!(Specialty, :slug, references["specialty_slug"], "la especialidad")
      }.merge(setting(references))
    end

    # A file written before cases carried a setting says nothing about it, and replaying
    # it must not erase a setting this database has since classified. Only a file that
    # names the key — nil included — decides it.
    def setting(references)
      return {} unless references.key?("setting_slug")

      { setting: find_by!(Specialty, :slug, references["setting_slug"], "el contexto") }
    end

    # Figures are rebuilt here by gpc:images rather than carried in the file, so a
    # missing one means that task has not run — say so instead of quietly dropping the
    # image out of a case that was written around it.
    def image_for(reference)
      return if reference.nil?

      section = section_for(reference)
      section.clinical_images.find_by(position: reference["position"]) ||
        missing("la figura #{reference["position"]} de la sección #{reference["section"]}")
    end

    def import_question(kase, attributes, counts)
      options = attributes.delete("options")
      reference = attributes.delete("recommendation")

      question = kase.questions.find_or_initialize_by(position: attributes["position"])
      counts[question.new_record? ? :questions_created : :questions_updated] += 1
      question.update!(attributes.merge(recommendation: recommendation_for(reference, attributes["source_quote"])))

      Array(options).each do |option|
        question.answer_options.find_or_initialize_by(position: option["position"]).update!(option)
      end
    end

    # The far side rebuilds recommendations with its own parser rather than receiving
    # them, so the path in the file — section and position — is only as stable as the
    # parser. Sections carved out of an archived PDF are named by it: a database that
    # kept an older carving because a case cited it (gpc:reparse never drops a cited row)
    # exports names a fresh reparse elsewhere does not produce. So the path is tried
    # first, and when it is gone or lands on a statement without the quote, the one
    # recommendation of that guideline that does contain the quote is used instead.
    # None or several and the path's answer stands: nothing, which fails as missing, or
    # the wrong statement, which Question's citation gate refuses. A case never arrives
    # mis-cited.
    def recommendation_for(reference, quote)
      return if reference.nil?

      guideline = find_by!(Guideline, :catalog_key, reference["catalog_key"], "la guía")
      at_path = guideline.guideline_sections.find_by(external_id: reference["section"])
        &.recommendations&.find_by(position: reference["position"])
      return at_path if quote.blank? || (at_path && Question.quote_in?(at_path.text, quote))

      by_quote = guideline.recommendations.select { |candidate| Question.quote_in?(candidate.text, quote) }
      return by_quote.sole if by_quote.one?

      at_path || missing(
        "la recomendación #{reference["position"]} de la sección #{reference["section"]} de #{guideline.catalog_key}"
      )
    end

    def section_for(reference)
      guideline = find_by!(Guideline, :catalog_key, reference["catalog_key"], "la guía")
      guideline.guideline_sections.find_by(external_id: reference["section"]) ||
        missing("la sección #{reference["section"]} de #{reference["catalog_key"]}")
    end

    def find_by!(model, column, value, noun)
      return if value.blank?

      model.find_by(column => value) || missing("#{noun} #{value}")
    end

    def missing(what)
      raise MissingReference, "#{what}, que no existe en esta base"
    end
  end
end
