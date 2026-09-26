require "rails_helper"

RSpec.describe Guideline do
  describe "validations" do
    it "requires a catalog key, a title and a content hash" do
      guideline = described_class.new

      expect(guideline).not_to be_valid
      expect(guideline.errors.attribute_names).to include(:catalog_key, :title, :content_hash)
    end

    it "rejects a second row for the same catalog key" do
      create(:guideline, catalog_key: "IMSS-028-22")

      expect(build(:guideline, catalog_key: "IMSS-028-22")).not_to be_valid
    end
  end

  describe ".generatable" do
    def with_statement(guideline)
      section = create(:guideline_section, guideline: guideline, kind: "recommendation")
      create(:recommendation, guideline_section: section)
      guideline
    end

    it "keeps a physician's guideline with something actionable in it" do
      guideline = with_statement(create(:guideline))
      create(:guideline, catalog_key: "IMSS-900-22")

      expect(described_class.generatable).to eq([guideline])
    end

    it "leaves out nursing guidelines" do
      with_statement(create(:guideline, title: "Intervenciones de Enfermería en el adulto mayor"))

      expect(described_class.generatable).to be_empty
    end

    # S- and SS- are the same institution, as are the two editions of SS-103.
    it "leaves out an edition a newer one of the same number has replaced" do
      older = with_statement(create(:guideline, catalog_key: "S-103-08", institution: "health_ministry", year: 2008))
      newer = with_statement(create(:guideline, catalog_key: "SS-103-21", institution: "health_ministry", year: 2021))

      expect(described_class.generatable).to eq([newer])
      expect(described_class.latest_editions).not_to include(older)
    end

    it "keeps the older edition while the newer one has no statements of its own" do
      older = with_statement(create(:guideline, catalog_key: "IMSS-076-08", year: 2008))
      create(:guideline, catalog_key: "IMSS-076-21", year: 2021)

      expect(described_class.generatable).to eq([older])
    end

    it "leaves out a guideline screened out of scope, and one not screened yet" do
      secondary = with_statement(create(:guideline, enarm_relevance: "secondary"))
      with_statement(create(:guideline, enarm_relevance: "out_of_scope"))
      unscreened = with_statement(create(:guideline, enarm_relevance: nil))

      expect(described_class.generatable).to eq([secondary])
      expect(described_class.screenable).to include(unscreened)
    end

    it "leaves out a guideline with no statement screened as a general physician's decision" do
      guideline = with_statement(create(:guideline))
      guideline.recommendations.update_all(decision_kind: "specialist")

      expect(described_class.generatable).to be_empty
    end
  end

  describe ".screening_pending" do
    def with_statement(guideline, decision_kind)
      section = create(:guideline_section, guideline: guideline, kind: "recommendation")
      create(:recommendation, guideline_section: section, decision_kind: decision_kind)
      guideline
    end

    it "holds a guideline never rated, or rated in scope with a statement still unlabelled" do
      unrated = with_statement(create(:guideline, enarm_relevance: nil), nil)
      unlabelled = with_statement(create(:guideline), nil)
      with_statement(create(:guideline), "process")
      with_statement(create(:guideline, enarm_relevance: "out_of_scope"), nil)

      expect(described_class.screening_pending).to contain_exactly(unrated, unlabelled)
    end
  end

  describe "#main_topic" do
    it "is the topic that accounts for most of the title" do
      guideline = create(:guideline)
      adult = create(:guideline_topic, guideline: guideline, relevance: 0.33).topic
      pediatric = create(:guideline_topic, guideline: guideline, relevance: 0.5).topic

      expect(guideline.main_topic).to eq(pediatric)
      expect(guideline.topics).to include(adult)
    end

    # "…en el primer nivel de atención" once filed conjunctivitis under primary care.
    it "prefers a troncal's topic to a setting's, however much of the title the setting matches" do
      guideline = create(:guideline)
      setting = create(:topic, branch: create(:branch, specialty: create(:specialty, kind: "cross_cutting")))
      create(:guideline_topic, guideline: guideline, topic: setting, relevance: 0.6)
      subject = create(:guideline_topic, guideline: guideline, relevance: 0.2).topic

      expect(guideline.main_topic).to eq(subject)
    end

    it "falls back to a setting's topic when the guideline names no subject" do
      guideline = create(:guideline)
      triage = create(:topic, branch: create(:branch, specialty: create(:specialty, kind: "cross_cutting")))
      create(:guideline_topic, guideline: guideline, topic: triage)

      expect(guideline.main_topic).to eq(triage)
    end

    it "is nil for a guideline no topic names" do
      expect(create(:guideline).main_topic).to be_nil
    end
  end

  describe ".institution_from_catalog_key" do
    it "maps each published prefix to its institution" do
      expect(described_class.institution_from_catalog_key("IMSS-028-22")).to eq("imss")
      expect(described_class.institution_from_catalog_key("SS-160-22")).to eq("health_ministry")
      expect(described_class.institution_from_catalog_key("DIF-400-21")).to eq("dif")
    end

    it "is case-insensitive, because the archive is not consistent about it" do
      expect(described_class.institution_from_catalog_key("imss-028-22")).to eq("imss")
    end

    it "returns nil for a prefix no institution claims" do
      expect(described_class.institution_from_catalog_key("XYZ-001-99")).to be_nil
      expect(described_class.institution_from_catalog_key(nil)).to be_nil
    end
  end

  describe ".with_specialty_label" do
    it "finds guidelines tagged with the label, including multi-specialty ones" do
      obstetrics = create(:guideline, specialty_labels: ["Gineco-Obstetricia"])
      both = create(:guideline, specialty_labels: ["Pediatría", "Medicina Interna"])
      create(:guideline, specialty_labels: ["Medicina Interna"])

      expect(described_class.with_specialty_label("Gineco-Obstetricia")).to contain_exactly(obstetrics)
      expect(described_class.with_specialty_label("Pediatría")).to contain_exactly(both)
    end
  end

  describe "enums" do
    it "exposes prefixed predicates for institution and source" do
      guideline = create(:guideline, institution: "imss", source: "live_site")

      expect(guideline).to be_institution_imss
      expect(guideline).to be_source_live_site
    end
  end

  # Guidelines carry their own shelf life — "de 3 a 5 años" — and it is why the live
  # catalog holds nothing older than 2020: CENETEC's successor republished only what was
  # still inside the window. Expired is a fact to show a student, not a reason to drop a
  # guideline: Cirugía General exists almost entirely among the expired ones.
  describe "validity" do
    around do |example|
      travel_to(Date.new(2026, 6, 1)) { example.run }
    end

    it "counts the last five years as current" do
      current = create(:guideline, year: 2021)
      create(:guideline, year: 2020)

      expect(described_class.current).to eq([current])
    end

    it "counts anything older as expired" do
      create(:guideline, year: 2021)
      expired = create(:guideline, year: 2008)

      expect(described_class.expired).to eq([expired])
    end

    it "treats a guideline with no year as neither, because unknown is not expired" do
      undated = create(:guideline, year: nil)

      expect(described_class.current).to be_empty
      expect(described_class.expired).to be_empty
      expect(described_class.undated).to eq([undated])
      expect(undated).not_to be_expired
    end

    it "says when a guideline runs out" do
      expect(build(:guideline, year: 2018).expires_on).to eq(Date.new(2023, 12, 31))
      expect(build(:guideline, year: nil).expires_on).to be_nil
    end

    it "answers #expired? consistently with the scopes" do
      expect(build(:guideline, year: 2018)).to be_expired
      expect(build(:guideline, year: 2024)).not_to be_expired
    end
  end

  describe "#source_url" do
    it "sends a live guideline to its own page on the government site" do
      guideline = build(
        :guideline, source: "live_site",
        document_url: "https://gpc.salud.gob.mx/DDIMBE/ContenidoGuia?DocumentoID=3079",
        catalog_url: "https://gpc.salud.gob.mx/DDIMBE"
      )

      expect(guideline.source_url).to eq("https://gpc.salud.gob.mx/DDIMBE/ContenidoGuia?DocumentoID=3079")
    end

    it "sends an archived guideline to the readable capture, not the raw-bytes form" do
      guideline = build(
        :guideline, source: "web_archive",
        catalog_url: "https://web.archive.org/web/20200605002220/http://x/ER.pdf",
        document_url: "https://web.archive.org/web/20200605002220id_/http://x/ER.pdf"
      )

      expect(guideline.source_url).to eq("https://web.archive.org/web/20200605002220/http://x/ER.pdf")
      expect(guideline.source_url).not_to include("id_/")
    end
  end
end
