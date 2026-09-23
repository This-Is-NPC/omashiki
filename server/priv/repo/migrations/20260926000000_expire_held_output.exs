defmodule Omashiki.Repo.Migrations.ExpireHeldOutput do
  use Ecto.Migration

  # A job in `review` names when its held output expires; recovery fails it
  # then, so no job waits in `review` without an end.
  def up do
    drop constraint(:jobs, :jobs_review_shape)

    create constraint(:jobs, :jobs_review_shape,
             check:
               "status <> 'review' OR (review IS NOT NULL AND (review->>'expires_at') IS NOT NULL)"
           )
  end

  def down do
    raise "no down - use mix ecto.reset"
  end
end
