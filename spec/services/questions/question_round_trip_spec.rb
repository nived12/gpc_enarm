require "rails_helper"

# The one file in this app that is worth real money. A generated case cannot be
# regenerated — the same prompt returns different wording and different distractors — so
# the round trip is tested as one thing, and the tests that matter most are the ones about
# a citation that fails to resolve on the far side.
RSpec.describe "question bank export and import" do
  let(:path) { Rails.root.join("tmp/spec-questions-#{SecureRandom.hex(4)}.jsonl.gz").to_s }

  after { FileUtils.rm_f(path) }

  def export = Questions::Exporter.call(path)
  def import = Questions::Importer.call(path)

  def build_bank
    guideline = create(:guideline, catalog_key: "IMSS-028-22")
    section = create(:guideline_section, guideline: guideline, external_id: "34142")
    recommendation = create(
      :recommendation, guideline_section: section, position: 3,
      text: "Se recomienda realizar electrocardiograma de 12 derivaciones."
    )
    kase = create(
      :clinical_case, guideline: guideline, topic: create(:topic), specialty: create(:specialty),
      generation_run: create(:generation_run, calls: 3, rejection_reasons: { "stem_asks_question" => 2 }),
      stem: "Paciente de 54 años con dolor torácico."
    )
    question = create(
      :question, clinical_case: kase, position: 1, recommendation: recommendation,
      source_quote: "electrocardiograma de 12 derivaciones"
    )
    create(:answer_option, question: question, position: 1, text: "Electrocardiograma", correct: true)
    create(
      :answer_option, question: question, position: 2, text: "Radiografía de tórax", correct: false,
      rationale: "La radiografía no muestra la isquemia.", rationale_verdict: "overstated", rationale_note: "Exagera."
    )
    kase
  end

  # The generated rows go; everything they point at stays, because the far side already
  # has the corpus and rebuilds the taxonomy from code.
  def clear_generated
    ClinicalCase.destroy_all
    GenerationRun.destroy_all
  end

  it "carries a case, its questions and its options across" do
    build_bank

    expect(export.payload).to include(runs: 1, cases: 1, questions: 1)

    clear_generated
    result = import

    expect(result).to be_success
    expect(result.payload).to include(cases_created: 1, questions_created: 1, runs_created: 1)
    expect(AnswerOption.count).to eq(2)
  end

  it "restores what the review screen reads" do
    build_bank
    export
    clear_generated
    import

    question = ClinicalCase.sole.questions.sole

    expect(question.source_quote).to eq("electrocardiograma de 12 derivaciones")
    expect(question.recommendation.text).to include("12 derivaciones")
    expect(question.correct_option.text).to eq("Electrocardiograma")
    expect(question.answer_options.second).to have_attributes(
      rationale: "La radiografía no muestra la isquemia.", rationale_verdict: "overstated", rationale_note: "Exagera."
    )
    expect(question.clinical_case.guideline.catalog_key).to eq("IMSS-028-22")
  end

  it "resolves references by key, whatever the row ids are on the far side" do
    build_bank
    export
    clear_generated
    # A fresh production database numbers its rows from somewhere else entirely.
    create(:recommendation, position: 3)
    import

    expect(ClinicalCase.sole.questions.sole.recommendation.guideline.catalog_key).to eq("IMSS-028-22")
  end

  it "is idempotent, so replaying a file does not pay for the batch twice" do
    build_bank
    export
    import

    expect(import.payload).to include(cases_updated: 1, questions_updated: 1, runs_updated: 1)
    expect(ClinicalCase.count).to eq(1)
    expect(AnswerOption.count).to eq(2)
  end

  it "keeps the run a case came from, so a bad prompt can still be retired wholesale" do
    kase = build_bank
    export
    key = kase.generation_run.export_key
    clear_generated
    import

    expect(ClinicalCase.sole.generation_run.export_key).to eq(key)
    expect(ClinicalCase.sole.generation_run).to have_attributes(
      calls: 3, rejection_reasons: { "stem_asks_question" => 2 }
    )
  end

  # An authored case has no run, no guideline and no citation; it still travels.
  it "carries a case that points at nothing" do
    kase = create(
      :clinical_case, guideline: nil, topic: nil, specialty: nil, generation_run: nil,
      source: "authored", stem: "Paciente de 30 años con fiebre."
    )
    create(:question, clinical_case: kase, recommendation: nil, source_quote: nil)
    export
    clear_generated

    expect(import).to be_success
    expect(ClinicalCase.sole).to have_attributes(
      guideline: nil, generation_run: nil,
      stem: "Paciente de 30 años con fiebre."
    )
    expect(Question.sole.recommendation).to be_nil
  end

  describe "the setting a case happens in" do
    def rewrite_file
      lines = Zlib::GzipReader.open(path) { |file| file.each_line.map { |line| JSON.parse(line) } }
      Zlib::GzipWriter.open(path) { |file| lines.each { |line| file.puts(yield(line).to_json) } }
    end

    it "carries the setting across by slug" do
      build_bank.update!(setting: create(:emergency_setting))
      export
      clear_generated
      import

      expect(ClinicalCase.sole.setting.slug).to eq("urgencias")
    end

    it "carries an unknown setting as unknown" do
      build_bank
      export
      clear_generated
      import

      expect(ClinicalCase.sole.setting).to be_nil
    end

    it "lets a newer file correct a setting, back to unknown included" do
      kase = build_bank
      export
      kase.update!(setting: create(:family_medicine_setting))
      import

      expect(kase.reload.setting).to be_nil
    end

    # A backup written before cases had a setting must not wipe out the settings
    # questions:classify_settings has filled in since.
    it "keeps the setting this database has when the file predates settings" do
      kase = build_bank
      export
      rewrite_file { |line| line.except("setting_slug") }
      family = create(:family_medicine_setting)
      kase.update!(setting: family)
      import

      expect(kase.reload.setting).to eq(family)
    end

    it "refuses a case whose setting this database does not have" do
      build_bank.update!(setting: create(:public_health_setting))
      export
      clear_generated
      Specialty.find_by(slug: "salud-publica").destroy

      expect(import.errors.full_messages.first).to include("el contexto salud-publica")
    end
  end

  describe "when a reference does not resolve on the far side" do
    it "refuses a case whose guideline this database does not have" do
      build_bank
      export
      clear_generated
      Guideline.destroy_all

      expect(import.errors.full_messages.first).to include("la guía IMSS-028-22, que no existe")
    end

    it "refuses a question whose recommendation was never rebuilt here" do
      build_bank
      export
      clear_generated
      Recommendation.destroy_all

      expect(import.errors.full_messages.first).to include("la recomendación 3 de la sección 34142")
    end

    it "refuses a case whose topic is missing rather than importing it unfiled" do
      build_bank
      export
      clear_generated
      Topic.destroy_all

      expect(import.errors.full_messages.first).to include("el tema")
    end

    # The far side runs its own parser over the stored sections, so a parser that numbers
    # a section differently hands back a different statement under the same position.
    # Nothing is missing, so only the quote can tell — and it does.
    it "refuses a question whose quote is not in the recommendation it landed on" do
      build_bank
      export
      clear_generated
      Recommendation.sole.update!(text: "Se recomienda vigilancia clínica estrecha.")

      expect(import.errors.full_messages.first).to include("no se pudo guardar")
    end

    # What production hit on its first load: a database that kept an older carving of
    # an archived PDF, because a case cited it, exports a section name a fresh reparse
    # elsewhere never produces. The quote still finds the statement.
    it "finds the recommendation by its quote when the far side named the section differently" do
      build_bank
      export
      clear_generated
      section = GuidelineSection.sole
      section.update!(external_id: "20180701235653/4-1-1-recommendation")
      Recommendation.sole.update!(position: 7)
      create(
        :recommendation, guideline_section: section, position: 3,
        text: "Se recomienda vigilancia clínica estrecha."
      )

      expect(import).to be_success
      expect(Question.sole.recommendation.text).to include("electrocardiograma de 12 derivaciones")
    end

    # A quote the generator took from the repaired text is only in the repaired text, and
    # the far side has it once gpc:import_repairs has run.
    it "finds the recommendation by a quote from its repaired text" do
      build_bank
      recommendation = Recommendation.sole
      recommendation.update!(
        text: "Se recomienda realizar SIGN 2008 electrocardiograma.",
        clean_text: "Se recomienda realizar electrocardiograma."
      )
      Question.sole.update!(source_quote: "realizar electrocardiograma")
      export
      clear_generated
      recommendation.update!(position: 7)
      create(
        :recommendation, guideline_section: recommendation.guideline_section, position: 3,
        text: "Se recomienda vigilancia clínica estrecha."
      )

      expect(import).to be_success
      expect(Question.sole.recommendation).to eq(recommendation)
    end

    it "refuses the question when the quote is in more than one recommendation of the guideline" do
      build_bank
      export
      clear_generated
      section = GuidelineSection.sole
      section.update!(external_id: "renamed")
      create(
        :recommendation, guideline_section: section, position: 9,
        text: "Tomar electrocardiograma de 12 derivaciones al ingreso."
      )

      expect(import.errors.full_messages.first).to include("la recomendación 3 de la sección 34142 de IMSS-028-22")
    end

    it "writes nothing at all when one question of a case fails" do
      build_bank
      export
      clear_generated
      Recommendation.destroy_all
      import

      expect(ClinicalCase.count).to eq(0)
    end
  end

  # After launch, review happens in production: a status set there, or a stem corrected
  # there, must survive the next batch arriving from the file.
  describe "importing new cases only" do
    def import_new = Questions::Importer.call(path, only_new: true)

    it "leaves a case the database already has, and its questions, exactly as they are" do
      kase = build_bank
      export
      kase.update!(status: "retired", stem: "Corregido en producción.")
      kase.questions.sole.update!(text: "¿Cuál es el siguiente paso, corregido?")
      kase.questions.sole.answer_options.first.update!(text: "ECG de 12 derivaciones")

      result = import_new

      expect(result).to be_success
      expect(result.payload).to include(cases_skipped: 1)
      expect(result.payload[:cases_updated]).to eq(0)
      expect(result.payload[:questions_updated]).to eq(0)
      expect(kase.reload).to have_attributes(status: "retired", stem: "Corregido en producción.")
      expect(kase.questions.sole.text).to eq("¿Cuál es el siguiente paso, corregido?")
      expect(kase.questions.sole.answer_options.first.text).to eq("ECG de 12 derivaciones")
    end

    describe "a second opinion on a case the database already has" do
      let(:earlier) { Time.zone.parse("2026-09-25 02:00") }
      let(:later) { Time.zone.parse("2026-09-26 02:00") }

      def judge(kase, verdict:, at:, rationale_verdict: "sound")
        kase.update!(verification_verdict: verdict, verified_at: at, verification_notes: "Nota #{verdict}.")
        kase.questions.sole.answer_options.second.update!(rationale_verdict: rationale_verdict, rationale_note: nil)
      end

      it "takes a live case off the bank when the file's opinion is newer, and says why" do
        kase = build_bank
        judge(kase, verdict: "flawed", at: later)
        export
        judge(kase, verdict: "supported", at: earlier, rationale_verdict: "overstated")
        kase.update!(status: "published")

        result = import_new

        expect(result.payload).to include(cases_skipped: 1, second_opinions_synced: 1)
        expect(kase.reload).to have_attributes(
          verification_verdict: "flawed", status: "draft", verified_at: later, verification_notes: "Nota flawed."
        )
        expect(kase.questions.sole.answer_options.second.rationale_verdict).to eq("sound")
      end

      # A file exported from a database that is behind must not roll production back.
      it "keeps production's verdict when the file's is older, or the file's case was never judged" do
        kase = build_bank
        judge(kase, verdict: "flawed", at: earlier)
        export
        judge(kase, verdict: "supported", at: later)

        import_new
        expect(kase.reload).to have_attributes(verification_verdict: "supported", verified_at: later)

        judge(kase, verdict: nil, at: nil)
        export
        judge(kase, verdict: "supported", at: later)

        import_new
        expect(kase.reload.verification_verdict).to eq("supported")
      end

      it "never puts a case on the bank, nor moves one a person withdrew" do
        kase = build_bank
        judge(kase, verdict: "supported", at: later)
        export
        judge(kase, verdict: "flawed", at: earlier)

        import_new
        expect(kase.reload).to have_attributes(verification_verdict: "supported", status: "draft")

        judge(kase, verdict: "flawed", at: later + 1.hour)
        export
        judge(kase, verdict: "supported", at: later)
        kase.update!(status: "retired")

        import_new
        expect(kase.reload).to have_attributes(verification_verdict: "flawed", status: "retired")
      end

      it "still moves the case verdict when production no longer has a question the file names" do
        kase = build_bank
        judge(kase, verdict: "flawed", at: later)
        export
        judge(kase, verdict: "supported", at: earlier)
        kase.questions.sole.destroy!

        expect(import_new.payload).to include(second_opinions_synced: 1)
        expect(kase.reload.verification_verdict).to eq("flawed")
      end

      it "leaves a rationale's verdict alone when production rewrote that rationale, or the file has none" do
        kase = build_bank
        judge(kase, verdict: "supported", at: earlier, rationale_verdict: nil)
        export
        option = kase.questions.sole.answer_options.second
        option.update!(rationale_verdict: "overstated")

        import_new
        expect(option.reload.rationale_verdict).to eq("overstated")

        judge(kase, verdict: "supported", at: earlier, rationale_verdict: "sound")
        export
        option.reload.update!(rationale: "Corregida en producción.", rationale_verdict: "overstated")

        import_new
        expect(option.reload).to have_attributes(rationale: "Corregida en producción.", rationale_verdict: "overstated")
      end
    end

    it "imports the cases the database lacks exactly as a full import would" do
      build_bank
      export
      clear_generated

      result = import_new

      expect(result).to be_success
      expect(result.payload).to include(cases_created: 1, questions_created: 1, runs_created: 1)
      expect(result.payload[:cases_skipped]).to eq(0)
      expect(ClinicalCase.sole.questions.sole.recommendation.text).to include("12 derivaciones")
      expect(AnswerOption.count).to eq(2)
    end

    it "skips the existing case and imports the new one from the same file" do
      kept = build_bank
      create(
        :clinical_case, guideline: nil, topic: nil, specialty: nil, generation_run: nil,
        source: "authored", stem: "Paciente de 30 años con fiebre."
      )
      export
      ClinicalCase.where.not(id: kept.id).destroy_all
      kept.update!(status: "flagged")

      result = import_new

      expect(result.payload).to include(cases_created: 1, cases_skipped: 1)
      expect(ClinicalCase.count).to eq(2)
      expect(kept.reload.status).to eq("flagged")
    end

    it "still refuses and names a new case whose citation does not resolve" do
      build_bank
      export
      clear_generated
      Recommendation.destroy_all

      result = import_new

      expect(result).to be_failure
      expect(result.errors.full_messages.first).to include("El caso", "la recomendación 3 de la sección 34142")
      expect(result.payload).to include(cases_refused: 1)
      expect(ClinicalCase.count).to eq(0)
    end
  end

  describe "the counts" do
    it "counts a refused case as refused, not as created" do
      build_bank
      export
      clear_generated
      Recommendation.destroy_all

      result = import

      expect(result.payload).to include(cases_refused: 1)
      expect(result.payload[:cases_created]).to eq(0)
      expect(result.payload[:questions_created]).to eq(0)
    end

    it "carries no counts when the file could not be read at all" do
      expect(Questions::Importer.call("#{path}-nope").payload).to be_nil
    end
  end

  describe "the figure a case was written around" do
    def build_with_figure
      kase = build_bank
      section = Guideline.find_by(catalog_key: "IMSS-028-22").guideline_sections.sole
      image = create(:clinical_image, :stored, guideline_section: section, position: 1)
      kase.update!(clinical_image: image)
      image
    end

    # The rows are rebuilt on the far side by gpc:images, the same way recommendations
    # are by gpc:reparse, so only the reference travels — a megabyte of bytes we can
    # fetch again for free has no business in the backup of the thing we cannot.
    it "carries the reference and resolves it against the far side's own rows" do
      build_with_figure
      export
      clear_generated
      import

      expect(ClinicalCase.sole.clinical_image.label).to eq("CUADRO 2")
    end

    it "carries nothing for a case that never had one" do
      build_bank
      export
      clear_generated
      import

      expect(ClinicalCase.sole.clinical_image).to be_nil
    end

    it "refuses the case when gpc:images has not been run here" do
      build_with_figure
      export
      clear_generated
      ClinicalImage.destroy_all

      expect(import.errors.full_messages.first).to include("la figura 1 de la sección")
    end
  end

  describe "when the file is not what it should be" do
    it "fails on a missing file" do
      expect(Questions::Importer.call("#{path}-nope").errors.full_messages.first).to include("No existe")
    end

    it "fails on a file that is not gzip" do
      File.write(path, "no soy gzip")

      expect(import.errors.full_messages.first).to include("no se pudo descomprimir")
    end

    it "fails on a line that is not JSON" do
      Zlib::GzipWriter.open(path) { |file| file.puts("{roto") }

      expect(import.errors.full_messages.first).to include("no es JSON")
    end

    it "fails on an unknown record type rather than skipping it" do
      Zlib::GzipWriter.open(path) { |file| file.puts({ record: "lo-que-sea" }.to_json) }

      expect(import.errors.full_messages.first).to include("Registro desconocido")
    end
  end
end
