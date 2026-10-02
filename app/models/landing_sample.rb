# The case a signed-out visitor answers on the landing page. Each visit draws one at
# random from a pool of ten, so a second visit shows something new (the owner's decision,
# 2026-09-23). A case is addressed by its export key (`/?caso=…`), which is what lets
# "Otro caso" link to a different one and a visitor send a friend the case they just did.
#
# FEATURED holds the export keys of the cases Dra. Guadarrama picks: export keys survive
# the move to another database, ids do not. Until ten are listed, or when a listed case is
# withdrawn, the pool tops up with published cases from the most recent guidelines. Only a
# case whose every question cites its recommendation qualifies, because the citation is
# what the page is there to show.
class LandingSample
  FEATURED = [].freeze
  POOL_SIZE = 10
  # The card sits beside the headline on a laptop; a full-workup vignette would push the
  # answers below the fold.
  MAX_STEM_LENGTH = 700

  Draw = Data.define(:clinical_case, :next_key)

  def self.draw(requested = nil)
    keys = pool_keys
    return if keys.empty?

    key = keys.include?(requested) ? requested : keys.sample
    clinical_case = ClinicalCase
      .includes(:specialty, questions: [:answer_options, { recommendation: [:guideline, :guideline_section] }])
      .find_by!(export_key: key)

    Draw.new(clinical_case: clinical_case, next_key: (keys - [key]).sample)
  end

  def self.pool_keys
    featured = eligible.where(export_key: FEATURED).limit(POOL_SIZE).pluck(:export_key)
    featured + eligible.where.not(export_key: featured).joins(:guideline)
      .order(Arel.sql("guidelines.year DESC NULLS LAST"), :id)
      .limit(POOL_SIZE - featured.size).pluck(:export_key)
  end

  def self.eligible
    fully_cited = Question.originals.group(:clinical_case_id)
      .having("COUNT(*) >= 2 AND COUNT(*) = COUNT(recommendation_id) AND COUNT(*) = COUNT(NULLIF(source_quote, ''))")
      .select(:clinical_case_id)

    ClinicalCase.status_published.where(locale: "es", id: fully_cited)
      .where("LENGTH(clinical_cases.stem) <= ?", MAX_STEM_LENGTH)
  end
end
