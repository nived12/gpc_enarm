# The size of the bank as the landing page shows it: live counts of what a student can
# actually practise, never a target. Whole-bank totals count cases, not areas, because a
# case is filed under two areas (see ClinicalCase.in_area). Cached for an hour: the page
# is the busiest one there is, and the bank only grows when a publish run finishes.
class LandingStats
  Counts = Data.define(:questions, :cases, :guidelines, :mock_questions)

  def self.current
    Rails.cache.fetch("landing_stats", expires_in: 1.hour) do
      published = ClinicalCase.status_published
      Counts.new(
        questions: Question.originals.where(clinical_case_id: published.select(:id)).count,
        cases: published.count,
        guidelines: published.distinct.count(:guideline_id),
        mock_questions: Exam::QUESTION_COUNTS.fetch("full_exam")
      )
    end
  end
end
