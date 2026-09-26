# When Questions::SourceScreener last tried a guideline, whatever came of it, so a
# guideline the model keeps failing on goes to the back of the queue instead of being
# paid for first on every run.
class AddScreenedAtToGuidelines < ActiveRecord::Migration[8.1]
  def change
    add_column :guidelines, :screened_at, :datetime
  end
end
