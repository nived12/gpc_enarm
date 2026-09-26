class AddScreeningToGuidelinesAndRecommendations < ActiveRecord::Migration[8.1]
  def change
    add_column :guidelines, :enarm_relevance, :string
    add_column :guidelines, :relevance_note, :string
    add_index :guidelines, :enarm_relevance

    add_column :recommendations, :decision_kind, :string
    add_index :recommendations, :decision_kind
  end
end
