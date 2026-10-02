require "rails_helper"

# The usage events sent to PostHog: one per milestone, never one per answer, and nothing
# that names the student. Analytics is inert in the suite, so each example checks the
# call, not the network.
RSpec.describe "Usage analytics", type: :request do
  let(:student) { create(:user) }

  before { allow(Analytics).to receive(:capture) }

  def sign_in(user = student)
    post session_path, params: { email: user.email, password: "contrasena-segura" }
  end

  def captured(event)
    have_received(:capture).with(anything, event, any_args)
  end

  describe "signed_up" do
    def register(email = "nueva@example.com")
      post registration_path, params: {
        user: { first_name: "Dana", last_name: "Ríos", email: email, password: "contrasena-segura",
                password_confirmation: "contrasena-segura" }
      }
      User.find_by!(email: email)
    end

    it "names the button that brought a password sign-up, and files it on the person" do
      get new_registration_path(from: "hero")
      user = register

      expect(Analytics).to have_received(:capture).with(
        user, "signed_up",
        method: "password", source: "hero", "$set_once": { sign_up_method: "password", sign_up_source: "hero" }
      )
    end

    it "keeps the source through a form sent twice, and forgets it once used" do
      get new_registration_path(from: "pricing_page")
      post registration_path,
        params: { user: { email: "nueva@example.com", password: "x", password_confirmation: "y" } }
      first = register
      delete session_path
      second = register("otra@example.com")

      expect(Analytics).to have_received(:capture).with(first, "signed_up", hash_including(source: "pricing_page"))
      expect(Analytics).to have_received(:capture).with(second, "signed_up", hash_including(source: "direct"))
    end

    it "keeps no source the links never send" do
      get new_registration_path(from: "<script>")
      user = register

      expect(Analytics).to have_received(:capture).with(user, "signed_up", hash_including(source: "direct"))
    end

    it "marks every sign-up link with where it is", :stripe do
      get new_session_path
      expect(response.body).to include(new_registration_path(from: "sign_in"))

      get pricing_path
      expect(response.body).to include(
        CGI.escapeHTML(
          new_registration_path(
            return_to: pricing_path(plan: "one_month", anchor: "plan-one_month"), from: "pricing_page"
          )
        )
      )
    end

    describe "with Google", :google do
      def continue_with_google
        post "/auth/google_oauth2", params: { time_zone: "" }
        follow_redirect!
      end

      it "carries the source across the round trip to Google" do
        mock_google
        get new_registration_path(from: "case")
        continue_with_google

        expect(Analytics).to have_received(:capture).with(
          User.sole, "signed_up",
          method: "google", source: "case", "$set_once": { sign_up_method: "google", sign_up_source: "case" }
        )
      end

      it "is not a sign-up when the account already existed" do
        mock_google
        student.identities.create!(provider: "google", uid: "108000000000000000001", email: student.email)

        continue_with_google

        expect(Analytics).not_to captured("signed_up")
      end
    end
  end

  describe "email_verified" do
    it "is sent the first time the link is followed, and not again" do
      user = create(:user, :unverified)
      link = verify_email_path(user.generate_token_for(:email_verification))

      get link
      get link

      expect(Analytics).to have_received(:capture).with(user, "email_verified").once
    end
  end

  describe "exams" do
    before { sign_in }

    let!(:kase) { create(:published_case, questions_count: 2) }

    it "reports a sitting started from the exams page, and its end" do
      post exams_path, params: { mode: "quick_quiz" }
      exam = Exam.last

      expect(Analytics).to have_received(:capture).with(
        student, "exam_started",
        mode: "quick_quiz", question_count: 2, feedback_timing: "after_each", timed: false, enarm_mode: false,
        from_study_plan: false
      )

      question = exam.exam_questions.first.question
      post exam_question_answer_path(exam, 1),
        params: { answer_option_id: question.answer_options.find_by!(correct: true).id }
      travel 3.minutes + 10.seconds
      patch complete_exam_path(exam)
      patch complete_exam_path(exam)

      expect(Analytics).to have_received(:capture).with(
        exam.user, "exam_finished",
        mode: "quick_quiz", question_count: 2, feedback_timing: "after_each", timed: false, enarm_mode: false,
        answered: 1, score: 50.0, minutes: 3, ran_out_of_time: false
      ).once
    end

    it "says when the clock ended it" do
      post exams_path, params: { mode: "full_exam" }
      exam = Exam.last
      travel 3.minutes

      get exam_path(exam)

      expect(Analytics).to have_received(:capture).with(
        exam.user, "exam_finished", hash_including(mode: "full_exam", timed: true, answered: 0, ran_out_of_time: true)
      )
    end

    it "sends nothing when no exam could be drawn" do
      post exams_path, params: { mode: "review" }

      expect(Analytics).not_to captured("exam_started")
    end
  end

  describe "the study plan" do
    let(:today) { Date.new(2026, 10, 5) }

    around { |example| travel_to(Time.find_zone("America/Mexico_City").local(2026, 10, 5, 12)) { example.run } }

    before do
      create_syllabus
      sign_in
    end

    it "reports a plan made, by its week and how far ahead the exam is" do
      post study_plan_path, params: { study_plan: { exam_date: (today + 60).iso8601, template: "five_days" } }

      expect(Analytics).to have_received(:capture).with(
        student, "study_plan_created", template: "five_days", weeks_to_exam: 8
      )
    end

    it "sends nothing for a plan it could not make" do
      post study_plan_path, params: { study_plan: { exam_date: (today + 3).iso8601, template: "six_days" } }

      expect(Analytics).not_to captured("study_plan_created")
    end

    it "tells a day's quiz from one the student chose" do
      result = StudyPlans::Builder.call(user: student, exam_date: (today + 60).iso8601, template: "six_days")
      day = result.payload[:plan].days.first
      create(:published_case, topic: day.topics.first, specialty: day.specialty, questions_count: 2)

      post quiz_study_plan_day_path(day.date)
      post quiz_study_plan_day_path(day.date)

      expect(Analytics).to have_received(:capture)
        .with(student, "exam_started", hash_including(from_study_plan: true)).once
    end
  end

  describe "pearls_session_finished" do
    before { sign_in }

    it "is sent on the tenth card, not on the ones before it" do
      kase = create(:published_case, questions_count: 1)
      statement = create(
        :recommendation, guideline_section: kase.questions.first.recommendation.guideline_section,
        text: "Se recomienda iniciar amoxicilina durante 10 días en la otitis media aguda."
      )

      post review_pearls_path, params: { recommendation_id: statement.id, grade: "good", step: 8 }
      expect(Analytics).not_to captured("pearls_session_finished")

      post review_pearls_path, params: { recommendation_id: statement.id, grade: "good", step: 9 }
      expect(Analytics).to have_received(:capture).with(student, "pearls_session_finished")
    end
  end

  describe "suggestion_submitted" do
    before { sign_in }

    it "sends the reason once per report, never the comment" do
      create(:published_case, questions_count: 1)
      post exams_path, params: { mode: "quick_quiz" }
      exam = Exam.last
      question = exam.exam_questions.first.question
      post exam_question_answer_path(exam, 1), params: { answer_option_id: question.answer_options.first.id }
      suggest = lambda do |reason|
        post exam_question_report_path(exam, 1),
          params: { question_report: { reason: reason, comment: "Mi correo es x@y.z" } }
      end

      suggest.call("")
      suggest.call("typo")
      suggest.call("incorrect_answer")

      expect(Analytics).to have_received(:capture).with(student, "suggestion_submitted", reason: "typo").once
      expect(Analytics).to captured("suggestion_submitted").once
    end
  end
end
