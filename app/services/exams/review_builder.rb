# Draws a review session: the published cases the student missed that are due today,
# most overdue first, as SM-2 scheduled them (Reviews::CaseScheduler).
#
# The order is the schedule's, not a shuffle: when more is due than one session holds,
# what has waited longest goes first and the rest waits for the next session.
module Exams
  class ReviewBuilder < Builder
    def call
      return failure(I18n.t("reviews.nothing_due")) if due_case_ids.empty?

      super
    end

    private

    def due_case_ids
      @due_case_ids ||= ReviewCard.where(user: user).published_cases.due(user.study_date)
                                  .order(:due_on, :id).pluck(:clinical_case_id)
    end

    def candidates
      counts = Question.originals.where(clinical_case_id: due_case_ids).group(:clinical_case_id).count
      specialties = ClinicalCase.where(id: due_case_ids).pluck(:id, :specialty_id).to_h
      due_case_ids.map { |id| [id, specialties[id], counts[id]] }
    end

    def ordered(rows)
      rows
    end
  end
end
