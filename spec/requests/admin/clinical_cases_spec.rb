require "rails_helper"

RSpec.describe "Admin review queue", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:reviewer) { create(:user, role: "reviewer") }

  def sign_in(user)
    post session_path, params: { email: user.email, password: "contrasena-segura" }
  end

  describe "GET /admin/clinical_cases" do
    let!(:published) { create(:published_case, stem: "Caso publicado sin problemas.") }
    let!(:disputed) { create(:clinical_case, verification_verdict: "unsupported", stem: "Caso sin respaldo.") }
    let!(:unverified) { create(:clinical_case, stem: "Caso sin verificar.") }
    let!(:flagged) do
      create(:clinical_case, verification_verdict: "supported", status: "flagged", stem: "Caso señalado.")
    end
    let!(:retired) do
      create(:clinical_case, verification_verdict: "supported", status: "retired", stem: "Caso retirado.")
    end
    let!(:reported) { create(:published_case, stem: "Caso con una sugerencia.") }

    before do
      create(:question_report, question: reported.questions.first)
      sign_in(reviewer)
    end

    it "holds what needs a person and leaves out what does not, linking each to the review screen" do
      get admin_clinical_cases_path

      expect(response.body).to include(disputed.stem, unverified.stem, flagged.stem, reported.stem)
      expect(response.body).not_to include(published.stem, retired.stem)
      expect(response.body).to include(review_clinical_case_path(disputed))
      expect(response.body).to include(I18n.t("admin.clinical_cases.open_reports", count: 1))
    end

    {
      "reported" => :reported, "flagged" => :flagged, "disputed" => :disputed,
      "unverified" => :unverified, "retired" => :retired
    }.each do |queue, kase|
      it "narrows to #{queue}" do
        get admin_clinical_cases_path(queue: queue)

        expected = public_send(kase)
        expect(response.body).to include(expected.stem)
        others = [disputed, unverified, flagged, retired, reported] - [expected]
        expect(response.body).not_to include(*others.map(&:stem))
      end
    end

    it "files a case the second opinion found flawed under disputed, with its note" do
      flawed = create(
        :clinical_case, verification_verdict: "flawed", stem: "Caso con defectos.",
        verification_notes: "1. otra opción también es correcta."
      )

      get admin_clinical_cases_path(queue: "disputed")

      expect(response.body).to include(flawed.stem, disputed.stem)
      expect(response.body).not_to include(unverified.stem)
    end

    it "says so when a queue is empty" do
      ClinicalCase.status_retired.update_all(status: "draft")

      get admin_clinical_cases_path(queue: "retired")

      expect(response.body).to include(I18n.t("admin.clinical_cases.empty.title"))
    end

    it "pages a long queue and keeps the queue on the page links" do
      create_list(:clinical_case, Admin::ClinicalCasesController::PER_PAGE + 1, verification_verdict: "ambiguous")

      get admin_clinical_cases_path(queue: "disputed")
      expect(response.body).to include("page=2&amp;queue=disputed")

      get admin_clinical_cases_path(queue: "disputed", page: 2)
      expect(response.body).to include("page=1&amp;queue=disputed")
    end

    it "offers a reviewer only the flag, and an admin every action that fits the case" do
      get admin_clinical_cases_path
      expect(response.body).to include(I18n.t("admin.clinical_cases.actions.flag"))
      expect(response.body).not_to include(I18n.t("admin.clinical_cases.actions.retire"))

      sign_in(admin)
      get admin_clinical_cases_path
      expect(response.body).to include(
        I18n.t("admin.clinical_cases.actions.retire"), I18n.t("admin.clinical_cases.actions.restore")
      )
    end
  end

  describe "PATCH /admin/clinical_cases/:id" do
    let(:kase) { create(:published_case) }

    def transition(name, referer: nil)
      patch admin_clinical_case_path(kase), params: { transition: name },
        headers: referer ? { "Referer" => referer } : {}
    end

    it "lets a reviewer flag a case, taking it away from students" do
      sign_in(reviewer)

      transition("flag", referer: review_clinical_case_url(kase))

      expect(kase.reload).to be_status_flagged
      expect(response).to redirect_to(review_clinical_case_url(kase))
      expect(flash[:notice]).to eq(I18n.t("admin.clinical_cases.done.flag", status: I18n.t("admin.statuses.flagged")))
    end

    it "keeps retiring and restoring from a reviewer" do
      sign_in(reviewer)

      transition("retire")
      expect(response).to have_http_status(:not_found)
      expect(kase.reload).to be_status_published
    end

    it "lets an admin retire a case" do
      sign_in(admin)

      transition("retire")

      expect(kase.reload).to be_status_retired
      expect(response).to redirect_to(admin_clinical_cases_path)
    end

    it "republishes a restored case through the publisher when the second opinion supported it" do
      kase.update!(status: "retired")
      bystander = create(:clinical_case, verification_verdict: "supported")
      sign_in(admin)

      transition("restore")

      expect(kase.reload).to be_status_published
      expect(bystander.reload).to be_status_draft
      expect(flash[:notice]).to include(I18n.t("admin.statuses.published"))
    end

    it "leaves a restored case in draft when the second opinion did not support it" do
      disputed = create(:clinical_case, verification_verdict: "ambiguous", status: "flagged")
      sign_in(admin)

      patch admin_clinical_case_path(disputed), params: { transition: "restore" }

      expect(disputed.reload).to be_status_draft
    end

    it "refuses a transition it does not know" do
      sign_in(admin)

      transition("publish")

      expect(response).to have_http_status(:unprocessable_content)
      expect(kase.reload).to be_status_published
    end

    it "is a 404 to a student" do
      sign_in(create(:user))

      transition("flag")

      expect(response).to have_http_status(:not_found)
      expect(kase.reload).to be_status_published
    end
  end

  describe "the review screen" do
    let(:kase) { create(:published_case) }

    before { sign_in(reviewer) }

    it "marks a case with open suggestions, on the list and on the case" do
      create(:question_report, question: kase.questions.second, reason: "typo", comment: "Dice «mg» donde va «mcg».")

      get review_clinical_cases_path
      expect(response.body).to include(I18n.t("admin.clinical_cases.open_reports", count: 1))

      get review_clinical_case_path(kase)
      expect(response.body).to include(
        I18n.t("admin.clinical_cases.open_reports", count: 1), I18n.t("question_reports.reasons.typo"),
        "Dice «mg» donde va «mcg».", admin_question_reports_path(case_id: kase.id)
      )
    end

    it "says a flagged case is withheld and offers nothing to flag again" do
      kase.update!(status: "flagged")

      get review_clinical_case_path(kase)

      expect(response.body).to include(I18n.t("admin.clinical_cases.flagged_notice"))
      expect(response.body).not_to include(I18n.t("admin.clinical_cases.open_reports", count: 1))
      expect(response.body).not_to include(">#{I18n.t("admin.clinical_cases.actions.flag")}<")
    end
  end
end
