require "rails_helper"

RSpec.describe "Exams", type: :request do
  let(:student) { create(:user) }

  def sign_in(user = student)
    post session_path, params: { email: user.email, password: "contrasena-segura" }
  end

  def start(mode = "quick_quiz", filters: {})
    post exams_path, params: { mode: mode, filters: filters }
    Exam.last
  end

  def answer(exam, position, text)
    exam_question = exam.exam_questions.find_by!(position: position)
    post exam_question_answer_path(exam, position),
      params: { answer_option_id: exam_question.question.answer_options.find_by!(text: text).id }
  end

  before { sign_in }

  it "turns away anyone not signed in" do
    delete session_path

    get new_exam_path

    expect(response).to redirect_to(new_session_path)
  end

  describe "choosing an exam" do
    it "offers the presets and the custom form, counting what is published" do
      create(
        :published_case, specialty: create(:specialty, name: "Pediatría"),
        topic: create(:topic, name: "Bronquiolitis")
      )

      get new_exam_path

      expect(response.body).to include(I18n.t("exams.modes.quick_quiz"), I18n.t("exams.modes.custom"))
      expect(response.body).to include(I18n.t("exams.new.bank", count: 1), "Pediatría", "Bronquiolitis")
    end

    # The number beside a box is what ticking it adds to the pool: for a context, the
    # cases about it and the cases set in it.
    it "counts each specialty as the builder draws it, the cases set in a context included" do
      internal = create(:specialty, name: "Medicina Interna", position: 1)
      family = create(:family_medicine_setting, position: 7)
      create_list(:published_case, 2, specialty: internal, setting: family)
      create(:published_case, specialty: internal, setting: nil)

      get new_exam_path

      page = Nokogiri::HTML(response.body)
      count_of = ->(specialty) { page.at_css("label:has(#filters_specialty_#{specialty.id}) .numeric").text.to_i }
      expect([count_of.call(internal), count_of.call(family)]).to eq([3, 2])
    end

    it "offers no box for a context with nothing about it or set in it" do
      create(:published_case, specialty: create(:specialty, name: "Pediatría"))
      family = create(:family_medicine_setting)

      get new_exam_path

      expect(response.body).not_to include("filters_specialty_#{family.id}")
    end

    it "says so plainly when nothing is published yet" do
      get new_exam_path

      expect(response.body).to include(I18n.t("home.dashboard.empty.title"))
    end

    it "starts at the first question" do
      create(:published_case)

      exam = start

      expect(response).to redirect_to(exam_question_path(exam, 1))
    end

    it "opens only the section a home button names" do
      create(:published_case)

      get new_exam_path(section: "mock")
      expect(response.body).to include(I18n.t("exams.new.mock.length"))
      expect(response.body).not_to include(
        I18n.t("exams.new.custom.question_count"),
        I18n.t("exams.new.presets.quick_quiz")
      )

      get new_exam_path(section: "custom")
      expect(response.body).to include(I18n.t("exams.new.custom.question_count"))
      expect(response.body).not_to include(I18n.t("exams.new.mock.length"))
    end

    it "sends the student back to the form they came from with the reason when nothing matches" do
      post exams_path, params: { mode: "custom" }
      expect(response).to redirect_to(new_exam_path(section: "custom"))

      post exams_path, params: { mode: "full_exam" }
      expect(response).to redirect_to(new_exam_path(section: "mock"))

      post exams_path, params: { mode: "quick_quiz" }

      expect(response).to redirect_to(new_exam_path)
      expect(flash[:alert]).to eq(I18n.t("exams.builder.nothing_matches"))
    end
  end

  describe "a practice exam" do
    let!(:kase) { create(:published_case, questions_count: 2, figure: true) }
    let(:exam) { start }

    it "shows the question with nothing that gives the answer away" do
      get exam_question_path(exam, 1)

      expect(response.body).to include(kase.stem, I18n.t("exams.question.submit"))
      expect(response.body).not_to include(I18n.t("exams.feedback.source"), "<figure", "<mark>")
      expect(response.body).not_to include("no es el estudio inicial")
    end

    it "shows the recommendation without the citation text the PDF left inside it" do
      exam.exam_questions.find_by(position: 1).question.recommendation.update!(
        text: "Se recomienda realizar electrocardiograma de 12 Scottish Intercollegiate derivaciones al llegar.",
        clean_text: "Se recomienda realizar electrocardiograma de 12 derivaciones al llegar.",
        removed_fragments: ["Scottish Intercollegiate"]
      )
      exam.exam_questions.find_by(position: 1).question.update!(
        source_quote: "electrocardiograma de 12 Scottish Intercollegiate derivaciones"
      )
      answer(exam, 1, "Troponina I")

      get exam_question_path(exam, 1)

      expect(response.body).to include("<mark>electrocardiograma de 12 derivaciones</mark> al llegar.")
      expect(response.body).not_to include("Scottish")
    end

    it "explains the answer on the same page once it is given, with the cited figure" do
      answer(exam, 1, "Troponina I")
      expect(response).to redirect_to(exam_question_path(exam, 1))

      get exam_question_path(exam, 1)

      expect(response.body).to include(I18n.t("exams.question.wrong"), I18n.t("exams.feedback.source"), "<mark>")
      expect(response.body).to include("CUADRO 2", I18n.t("exams.triage.prompt"), kase.guideline.catalog_key)
      expect(response.body).to include(
        "Troponina I no es el estudio inicial",
        "Ecocardiograma no es el estudio inicial"
      )
    end

    # The cheap generator overstates; a rationale the second opinion rejected would
    # teach a rule no guideline wrote.
    it "never shows a rationale the second opinion rejected, and shows the ones it has not judged" do
      options = kase.questions.first.answer_options
      options.find_by!(text: "Troponina I").update!(rationale_verdict: "overstated", rationale_note: "Exagera.")
      options.find_by!(text: "Ecocardiograma").update!(rationale_verdict: "sound")
      answer(exam, 1, "Troponina I")

      get exam_question_path(exam, 1)

      expect(response.body).not_to include("Troponina I no es el estudio inicial", "Exagera.")
      expect(response.body).to include(
        "Ecocardiograma no es el estudio inicial",
        "Radiografía de tórax no es el estudio"
      )
    end

    it "warns when the cited guideline is past its validity" do
      kase.guideline.update!(year: 2008)
      answer(exam, 1, "Troponina I")

      get exam_question_path(exam, 1)

      expect(response.body).to include(I18n.t("exams.feedback.expired"))
    end

    it "lets a question be left for later and brings it round again after the rest" do
      get exam_question_path(exam, 1)
      expect(response.body).to include(I18n.t("exams.question.skip"), exam_question_path(exam, 2))
      expect(response.body).to include('<meta name="turbo-cache-control" content="no-preview">')

      get exam_question_path(exam, 2)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("exams.question.previous"), exam_question_path(exam, 1))

      answer(exam, 2, "Electrocardiograma de 12 derivaciones")
      get exam_question_path(exam, 2)

      expect(response.body).to include(I18n.t("exams.question.next"))
      expect(response.body).to include("href=\"#{exam_question_path(exam, 1)}\"")
      expect(exam.current_question.position).to eq(1)
    end

    it "keeps an explained answer as it was" do
      answer(exam, 1, "Troponina I")
      answer(exam, 1, "Electrocardiograma de 12 derivaciones")

      expect(flash[:alert]).to eq(I18n.t("exams.answers.already_answered"))
      expect(Answer.last).not_to be_correct
    end

    it "maps every question, and warns before finishing with some unanswered" do
      answer(exam, 1, "Troponina I")

      get exam_question_path(exam, 1)

      expect(response.body).to include(I18n.t("exams.question.map.title"), I18n.t("exams.question.map.wrong"))
      expect(response.body).to include(I18n.t("exams.question.map.unanswered"), "aria-current=\"step\"")
      expect(response.body).to include(CGI.escapeHTML(I18n.t("exams.question.map.confirm_finish", count: 1)))
    end

    it "offers the results after the last explanation" do
      answer(exam, 1, "Troponina I")
      answer(exam, 2, "Electrocardiograma de 12 derivaciones")

      get exam_question_path(exam, 2)

      expect(response.body).to include(I18n.t("exams.question.see_results"))
    end

    it "sends a refused answer back to the question with the reason" do
      post exam_question_answer_path(exam, 1), params: { answer_option_id: "" }

      expect(response).to redirect_to(exam_question_path(exam, 1))
      expect(flash[:alert]).to eq(I18n.t("exams.answers.choose_option"))
    end

    it "is another student's business only to 404" do
      exam
      delete session_path
      sign_in(create(:user))

      get exam_question_path(exam, 1)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "why a wrong answer was wrong" do
    let!(:kase) { create(:published_case, questions_count: 2) }
    let(:exam) { start }

    def triage(reason)
      patch exam_question_answer_path(exam, 1), params: { answer: { error_reason: reason } }
    end

    it "records the student's reason in place, and clears it on a second tap" do
      answer(exam, 1, "Troponina I")

      triage("confused_diagnoses")
      expect(response.body).to include("turbo-frame", "aria-pressed=\"true\"")
      expect(Answer.last).to be_error_confused_diagnoses

      triage("")
      expect(Answer.last.error_reason).to be_nil
    end

    it "refuses a reason the interface does not offer" do
      answer(exam, 1, "Troponina I")

      triage("guessed")

      expect(response).to have_http_status(:unprocessable_content)
      expect(Answer.last.error_reason).to be_nil
    end

    it "has nothing to ask about a right answer, or an unanswered one" do
      triage("did_not_know")
      expect(response).to have_http_status(:not_found)

      answer(exam, 1, "Electrocardiograma de 12 derivaciones")
      triage("did_not_know")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a mock exam on a single page" do
    let!(:cases) { [create(:published_case, questions_count: 2), create(:published_case, questions_count: 1)] }
    let(:exam) { start("full_exam") }

    def choose(position, text, format: :turbo_stream)
      exam_question = exam.exam_questions.find_by!(position: position)
      post exam_question_answer_path(exam, position),
        headers: format == :turbo_stream ? { "Accept" => "text/vnd.turbo-stream.html" } : {},
        params: { answer_option_id: exam_question.question.answer_options.find_by!(text: text).id }
    end

    it "opens on the whole exam: every case and question, nothing that gives an answer away" do
      post exams_path, params: { mode: "full_exam" }
      expect(response).to redirect_to(exam_path(Exam.last))

      get exam_path(Exam.last)

      expect(response.body).to include(*cases.map(&:stem), I18n.t("exams.sheet.answered", answered: 0, total: 3))
      expect(response.body).not_to include(I18n.t("exams.feedback.source"), "<mark>", I18n.t("exams.question.wrong"))
    end

    it "heads every question as the real booklet does, and states the real conditions" do
      get exam_path(exam)
      expect(response.body).to include(*(1..3).map { |n| I18n.t("exams.sheet.question_heading", number: n) })

      get new_exam_path
      expect(response.body).to include(I18n.t("exams.new.mock.imperfect_options"))
    end

    it "warns once, twenty minutes before the end, and not before" do
      get exam_path(exam)
      expect(response.body).to match(/role="status" id="final_warning_exam_#{exam.id}"\s*>/)

      stub_const("Exam::FINAL_WARNING_SECONDS", 60)
      get exam_path(exam)
      expect(response.body).to match(/id="final_warning_exam_#{exam.id}"\s*hidden>/)
    end

    it "saves each choice in place, in any order, and a change of mind replaces it" do
      choose(3, "Troponina I")
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(
        I18n.t("exams.sheet.saved"),
        I18n.t("exams.sheet.answered", answered: 1, total: 3)
      )

      choose(3, "Electrocardiograma de 12 derivaciones")
      expect(exam.exam_questions.find_by!(position: 3).answer).to be_correct
      expect(response.body).not_to include(I18n.t("exams.question.right"))

      get exam_path(exam)
      expect(response.body).to include("checked=\"checked\"")
    end

    it "falls back to a plain redirect to the question without JavaScript" do
      choose(2, "Troponina I", format: :html)

      expect(response).to redirect_to(exam_path(exam, anchor: "exam_question_#{exam.exam_questions.second.id}"))
    end

    it "sends a question's own page back to its place on the sheet" do
      get exam_question_path(exam, 2)

      expect(response).to redirect_to(exam_path(exam, anchor: "exam_question_#{exam.exam_questions.second.id}"))
    end

    it "asks nothing about a wrong answer until the exam is over — the question would give it away" do
      choose(1, "Troponina I")

      patch exam_question_answer_path(exam, 1), params: { answer: { error_reason: "did_not_know" } }

      expect(response).to have_http_status(:not_found)
    end

    it "shows the results and every explanation once finished" do
      choose(1, "Troponina I")
      choose(2, "Electrocardiograma de 12 derivaciones")

      patch complete_exam_path(exam)
      follow_redirect!
      expect(response.body).to include("33.3%", I18n.t("exams.results.tally", correct: 1, total: 3))
      expect(response.body).to include(I18n.t("exams.results.pace", seconds: 0, real: 77))

      get exam_question_path(exam, 3)
      expect(response.body).to include(I18n.t("exams.question.unanswered"), I18n.t("exams.feedback.source"))
      expect(response.body).to include(I18n.t("exams.question.back_to_results"))
    end

    it "ends the exam when the clock runs out" do
      exam.update!(running_since: 4.minutes.ago)

      choose(1, "Troponina I")

      expect(response).to redirect_to(exam_path(exam))
      expect(flash[:alert]).to eq(I18n.t("exams.answers.time_up"))
    end

    it "sends a question visited after the clock ran out to the exam, which ends it" do
      exam.update!(running_since: 4.minutes.ago)

      get exam_question_path(exam, 1)

      expect(response).to redirect_to(exam_path(exam))
    end

    it "finishes on its own when the clock is found out at the exam page" do
      exam.update!(running_since: 4.minutes.ago)

      get exam_path(exam)

      expect(exam.reload).to be_status_completed
      expect(response.body).to include(I18n.t("exams.results.blank"))
    end

    it "breaks the results down by specialty when there is more than one" do
      specialties = [create(:specialty, name: "Pediatría"), create(:specialty, name: "Cirugía General")]
      cases.zip(specialties).each { |kase, specialty| kase.update!(specialty: specialty) }
      patch complete_exam_path(exam)

      get exam_path(exam)

      expect(response.body).to include(I18n.t("exams.results.by_specialty"), "Pediatría", "Cirugía General")
      expect(response.body).not_to include(I18n.t("exams.results.by_specialty_overlap"))
    end

    it "says why the specialty rows add up to more than the exam when a case counts in two" do
      emergency = create(:emergency_setting)
      cases.each { |kase| kase.update!(specialty: create(:specialty), setting: emergency) }
      patch complete_exam_path(exam)

      get exam_path(exam)

      expect(response.body).to include("Urgencias", I18n.t("exams.results.by_specialty_overlap"))
    end

    it "goes one question at a time when the student asks for explanations as they answer" do
      post exams_path,
        params: { mode: "full_exam", settings: { feedback_timing: "after_each", seconds_per_question: "" } }

      expect(response).to redirect_to(exam_question_path(Exam.last, 1))
      expect(Exam.last.time_limit_seconds).to be_nil
    end
  end

  describe "the finish screen, one question at a time" do
    before { create(:published_case, questions_count: 1) }

    it "asks before finishing once every question has an answer" do
      exam = start
      answer(exam, 1, "Troponina I")

      get exam_path(exam)

      expect(response.body).to include(I18n.t("exams.finish.title"))
    end
  end

  describe "pausing" do
    before { create(:published_case, questions_count: 2) }

    let(:exam) { start }

    it "stops the clock, shows where the student stopped, and picks up there" do
      answer(exam, 1, "Troponina I")

      patch pause_exam_path(exam)
      follow_redirect!
      expect(response.body).to include(I18n.t("exams.paused.progress", answered: 1, total: 2))

      get exam_question_path(exam, 2)
      expect(response).to redirect_to(exam_path(exam))

      patch resume_exam_path(exam)
      expect(response).to redirect_to(exam_path(exam))
      follow_redirect!
      expect(response).to redirect_to(exam_question_path(exam, 2))
    end
  end

  describe "discarding an exam started by mistake" do
    before { create(:published_case) }

    let(:exam) { start }

    it "takes it out of the student's view, asking first" do
      get exam_question_path(exam, 1)
      expect(response.body).to include(I18n.t("exams.discard.button"), I18n.t("exams.discard.confirm"))

      delete exam_path(exam)

      expect(response).to redirect_to(root_path)
      expect(exam.reload).to be_status_discarded
      get exams_path
      expect(response.body).to include(I18n.t("exams.index.empty.title"))
      get exam_path(exam)
      expect(response).to redirect_to(root_path)
    end

    it "discards a finished one too, from its results, and takes it out of the average" do
      patch complete_exam_path(exam)
      get exam_path(exam)
      expect(response.body).to include(I18n.t("exams.discard.button"))

      delete exam_path(exam)

      expect(response).to redirect_to(exams_path)
      expect(exam.reload).to be_status_discarded
      get root_path
      expect(response.body).to include(I18n.t("home.dashboard.no_average"))
    end
  end

  describe "the history and the home screen" do
    it "lists past exams with their score, and the unfinished ones to continue" do
      create(:exam, user: student, status: "completed", score: 72.5, completed_at: Time.current)
      create(:exam, user: student)

      get exams_path

      expect(response.body).to include("72.5%", I18n.t("exams.index.continue"))
    end

    it "says so when there is no history yet" do
      get exams_path

      expect(response.body).to include(I18n.t("exams.index.empty.title"))
    end

    it "shows the average, where the student left off, and the button that starts a quiz" do
      create(:published_case)
      create(:exam, user: student, status: "completed", score: 60, completed_at: Time.current)
      create(:exam, user: student, status: "completed", score: 80, completed_at: Time.current)
      create(:exam, user: student, status: "paused", running_since: nil)

      get root_path

      expect(response.body).to include("70%", I18n.t("home.dashboard.completed", count: 2))
      expect(response.body).to include(I18n.t("home.dashboard.unfinished", mode: I18n.t("exams.modes.quick_quiz")))
      expect(response.body).to include(I18n.t("home.dashboard.start_quiz"))
    end

    it "shows no average before the first finished exam" do
      create(:published_case)

      get root_path

      expect(response.body).to include(I18n.t("home.dashboard.no_average"))
    end
  end
end
