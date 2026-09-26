require "rails_helper"

# The two read-only screens: what the LLM work cost, and what the corpus holds.
RSpec.describe "Admin costs and ingestion", type: :request do
  before { post session_path, params: { email: create(:user, :admin).email, password: "contrasena-segura" } }

  describe "GET /admin/costs" do
    it "totals runs, tokens and dollars per purpose, provider and model" do
      create(
        :generation_run, purpose: "generation", provider: "gemini", model: "gemini-3.1-flash-lite",
        input_tokens: 1_000, output_tokens: 500, cost_usd: 0.20
      )
      create(
        :generation_run, purpose: "generation", provider: "gemini", model: "gemini-3.1-flash-lite",
        input_tokens: 2_000, output_tokens: 500, cost_usd: 0.05
      )
      create(
        :generation_run, purpose: "verification", provider: "deepseek", model: "deepseek-flash",
        input_tokens: 100, output_tokens: 100, cost_usd: 0.0125
      )

      get admin_costs_path

      expect(response.body).to include(
        "US$0.2500", "US$0.0125", "US$0.2625", "3,000", "deepseek · deepseek-flash",
        I18n.t("admin.costs.purposes.verification"), I18n.t("admin.costs.total_detail", runs: 3, tokens: "4,200")
      )
      expect(response.body).to include("width: 100.0%", "width: 5.0%")
    end

    it "names every purpose in the interface's language" do
      GenerationRun.purposes.each_key { |purpose| create(:generation_run, purpose: purpose) }

      get admin_costs_path

      expect(response.body).not_to include("translation_missing", "Translation missing")
      expect(response.body).to include(I18n.t("admin.costs.purposes.screening"))
    end

    it "says so when nothing has run yet" do
      get admin_costs_path

      expect(response.body).to include(I18n.t("admin.costs.empty.title"))
    end
  end

  describe "GET /admin/ingestion" do
    it "counts guidelines by source and by whether they yielded statements, and cases by specialty" do
      cited = create(:recommendation).guideline_section.guideline
      create(:guideline, source: "web_archive", year: 2010)
      create(:guideline, year: nil)
      specialty = create(:specialty, name: "Pediatría")
      create(:published_case, specialty: specialty, guideline: cited)
      create(:clinical_case, specialty: specialty)
      create(:clinical_case)

      get admin_ingestion_path

      body = response.body
      expect(body).to include(I18n.t("admin.ingestion.with_statements", count: 1, total: 2))
      expect(body).to include(I18n.t("admin.ingestion.with_statements", count: 0, total: 1))
      expect(body).to include("Pediatría", I18n.t("admin.ingestion.unfiled"))
    end

    it "says how many guidelines are still to screen before generating" do
      create(
        :recommendation,
        guideline_section: create(:guideline_section, guideline: create(:guideline, enarm_relevance: nil))
      )

      get admin_ingestion_path

      expect(response.body).to include(I18n.t("admin.ingestion.counts.screening_pending"))
    end

    it "shows how the published cases spread over the three contexts, and how many have none" do
      emergency = create(:emergency_setting)
      create_list(:published_case, 2, setting: emergency)
      create(:published_case, setting: nil)
      create(:clinical_case, setting: emergency)

      get admin_ingestion_path

      row = Nokogiri::HTML(response.body).css("tr").find { |tr| tr.at_css("th")&.text == "Urgencias" }
      expect(row.css("td").map(&:text)).to eq(%w[0 0 2])
      expect(response.body).to include(I18n.t("admin.ingestion.no_setting", count: 1))
    end

    it "leaves out the unfiled row when every case has a specialty" do
      get admin_ingestion_path

      expect(response.body).not_to include(
        I18n.t("admin.ingestion.unfiled"),
        I18n.t("admin.ingestion.no_setting", count: 0)
      )
      expect(response.body).to include(I18n.t("admin.ingestion.with_statements", count: 0, total: 0))
    end
  end
end
