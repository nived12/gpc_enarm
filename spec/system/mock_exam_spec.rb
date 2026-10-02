require "rails_helper"

# The exam as the real one is sat: every case on one page, answers saved as they are
# chosen and changeable until the end, and a clock that ends the sitting by itself.
RSpec.describe "Simulacro ENARM", type: :system do
  let(:student) { create(:user, first_name: "Ana") }

  before do
    create(:published_case, questions_count: 2)
    create(:published_case, questions_count: 1)
  end

  def start_mock_exam(enarm_mode: false)
    sign_in_as(student)
    click_link I18n.t("home.dashboard.mock_exam")
    expect(page).to have_no_text(I18n.t("exams.new.sections.custom.title"))
    uncheck I18n.t("exams.new.mock.enarm_mode.label"), allow_label_click: true unless enarm_mode
    click_button I18n.t("exams.new.mock.submit")
    expect(page).to have_text(I18n.t("exams.sheet.answered", answered: 0, total: 3))
  end

  it "answers in any order on one page, changes an answer, keeps them on reload and finishes", viewport: :phone do
    start_mock_exam
    expect(page).to have_css("article", count: 3)
    expect(page).to have_no_text(label("exams.feedback.source"))
    expect_no_sideways_scroll

    within(all("article").last) { find("label", text: "Troponina I").click }
    expect(page).to have_text(I18n.t("exams.sheet.answered", answered: 1, total: 3))
    within(all("article").first) { find("label", text: "Radiografía de tórax").click }
    expect(page).to have_text(I18n.t("exams.sheet.answered", answered: 2, total: 3))
    within(all("article").last) { find("label", text: "Electrocardiograma de 12 derivaciones").click }
    # The note from the first save is already on screen, so wait for the change itself.
    answer = Exam.last.exam_questions.find_by!(position: 3).answer
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until answer.reload.answer_option.text.start_with?("Electro")
    end

    visit current_path
    within(all("article").last) do
      expect(find("input[type=radio]:checked", visible: :all).find(:xpath, "..")).to have_text("Electrocardiograma")
    end

    accept_confirm { click_button I18n.t("exams.sheet.finish") }
    expect(page).to have_text(I18n.t("exams.results.tally", correct: 1, total: 3))
    expect_no_sideways_scroll
  end

  it "holds a confidence icon tapped first until an option is chosen, then saves both", viewport: :phone do
    start_mock_exam
    guess = I18n.t("exams.confidence.levels.guess")

    within(all("article").first) do
      find("label[title='#{guess}']").click
      expect(page).to have_no_text(I18n.t("exams.sheet.saved"))
      find("label", text: "Troponina I").click
      expect(page).to have_text(I18n.t("exams.sheet.saved"))
    end
    expect(Exam.last.answers.sole).to have_attributes(confidence: "guess", correct: false)

    within(all("article").first) { find("label[title='#{I18n.t("exams.confidence.levels.sure")}']").click }
    # Saved in the background; reloading before it lands would read the old value.
    Timeout.timeout(Capybara.default_max_wait_time) { sleep 0.05 until Exam.last.answers.sole.reload.confidence_sure? }
    visit current_path
    within(all("article").first) { expect(page).to have_checked_field("confidence", with: "sure", visible: :all) }
    expect_no_sideways_scroll
  end

  # Modo ENARM: the booklet prints the options as text and the answers go on the sheet,
  # which on a phone opens over the booklet and closes back to it.
  def bubble(number, letter)
    find("[aria-label='#{I18n.t("exams.booklet.bubble", number: number, letter: letter)}']", visible: :all).find(
      :xpath, ".."
    )
  end

  it "reads the booklet and marks the answer sheet, as the real sitting does", viewport: :phone do
    start_mock_exam(enarm_mode: true)
    expect(page).to have_css("article", count: 3)
    expect(page).to have_no_css("article input[type=radio]", visible: :all)
    expect_no_sideways_scroll

    click_button I18n.t("exams.booklet.open_sheet")
    expect(page).to have_css("[role=dialog][aria-modal=true]")
    bubble(3, "A").click
    expect(page).to have_text(I18n.t("exams.sheet.answered", answered: 1, total: 3))
    answer = Exam.last.exam_questions.find_by!(position: 3).answer
    first_choice = answer.answer_option_id
    bubble(3, "B").click
    Timeout.timeout(Capybara.default_max_wait_time) { sleep 0.05 until answer.reload.answer_option_id != first_choice }
    page.send_keys(:escape)
    expect(page).to have_no_css("[role=dialog]")
    expect(page).to have_button(I18n.t("exams.booklet.open_sheet"), focused: true)

    visit current_path
    click_button I18n.t("exams.booklet.open_sheet")
    expect(bubble(3, "B").find("input", visible: :all)).to be_checked
    expect(Exam.last).to be_enarm_mode.and be_feedback_at_end
  end

  it "ends the sitting by itself when the clock reaches zero" do
    start_mock_exam
    within(all("article").first) { find("label", text: "Electrocardiograma de 12 derivaciones").click }
    expect(page).to have_text(I18n.t("exams.sheet.answered", answered: 1, total: 3))

    # Three seconds left on the server's clock; the page counts them down and finishes.
    exam = Exam.last
    exam.update!(running_since: (exam.time_limit_seconds - 3).seconds.ago)
    visit current_path

    expect(page).to have_text(I18n.t("exams.results.tally", correct: 1, total: 3), wait: 10)
    expect(exam.reload).to be_status_completed
  end
end
