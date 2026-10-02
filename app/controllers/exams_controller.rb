# Building an exam, and everything around a sitting that is not a question: the pause
# screen, the finish screen and the results.
class ExamsController < ApplicationController
  include UpgradePath

  before_action :set_exam, only: %i[show pause resume complete destroy]

  HISTORY_LIMIT = 50

  def index
    @exams = Current.user.exams.kept.recent.limit(HISTORY_LIMIT)
  end

  SECTIONS = %w[mock custom].freeze

  def new
    @section = params[:section].presence_in(SECTIONS)
    @published = ClinicalCase.status_published
    # By area, as Exams::Builder draws them: the count beside Urgencias is every case
    # about it or set in it, which is exactly what ticking it adds to the pool.
    @specialty_counts = @published.count_by_area
    @specialties = Specialty.in_reading_order.where(id: @specialty_counts.keys)
    @topic_counts = @published.group(:topic_id).count
    @topics = Topic.where(id: @published.select(:topic_id)).includes(branch: :specialty)
                   .sort_by { |topic| [topic.branch.specialty.position, topic.name] }
  end

  # The review session and the weak-spot quiz choose their own cases; every other mode
  # is drawn by the general builder.
  BUILDERS = { "review" => Exams::ReviewBuilder, "weak_spots" => Exams::WeakSpotBuilder }.freeze

  def create
    result = BUILDERS.fetch(params[:mode].to_s, Exams::Builder).call(
      user: Current.user, mode: params[:mode], filters: filter_params,
      settings: setting_params
    )
    if result.failure?
      return redirect_to_upgrade(result) if daily_limit_reached?(result)

      return redirect_to(
        new_exam_path(section: section_for(params[:mode])),
        alert: result.errors.full_messages.to_sentence
      )
    end

    exam = result.payload[:exam]
    Analytics.capture(Current.user, "exam_started", exam.usage_properties.merge(from_study_plan: false))
    redirect_to exam.feedback_at_end? ? exam_path(exam) : exam_question_path(exam, 1)
  end

  def show
    return redirect_to(root_path) if @exam.status_discarded?

    @exam.complete! if @exam.status_in_progress? && @exam.time_up?
    return render(:results) if @exam.status_completed?
    return render(:paused) if @exam.status_paused?
    return render(:sheet) if @exam.feedback_at_end?

    current = @exam.current_question
    redirect_to exam_question_path(@exam, current.position) if current
  end

  # A finished exam is discarded from its results or the history, so the student goes
  # back to the history; an unfinished one is left from inside it, so they go home.
  def destroy
    destination = @exam.status_completed? ? exams_path : root_path
    @exam.discard!
    redirect_to destination, notice: t("exams.discard.done"), status: :see_other
  end

  def pause
    @exam.pause!
    redirect_to exam_path(@exam)
  end

  def resume
    @exam.resume!
    redirect_to exam_path(@exam)
  end

  def complete
    @exam.complete!
    redirect_to exam_path(@exam)
  end

  private

  # Scoped to the student, so another student's exam is a 404 rather than a page.
  def set_exam
    @exam = Current.user.exams.find(params[:id])
  end

  def section_for(mode)
    return "custom" if %w[custom weak_spots].include?(mode)

    "mock" if Exam::EXAM_LENGTH_MODES.include?(mode)
  end

  def setting_params
    params.fetch(:settings, {}).permit(:feedback_timing, :seconds_per_question, :enarm_mode)
  end

  def filter_params
    params.fetch(:filters, {}).permit(
      :question_count, :unseen_only, :previously_wrong_only, :interleave,
      specialty_ids: [], topic_ids: [], difficulties: []
    )
  end
end
