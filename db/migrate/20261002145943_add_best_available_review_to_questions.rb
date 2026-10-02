# The second opinion on a best-available version, kept on the version, and the moment
# the generator declined to write one, kept on the original so no run pays to ask again.
class AddBestAvailableReviewToQuestions < ActiveRecord::Migration[8.1]
  def change
    change_table :questions, bulk: true do |t|
      t.string :best_available_verdict
      t.text :best_available_note
      t.datetime :best_available_declined_at
    end
  end
end
