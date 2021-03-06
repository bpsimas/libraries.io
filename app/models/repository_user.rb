class RepositoryUser < ApplicationRecord
  has_many :contributions, dependent: :delete_all
  has_many :repositories
  has_many :source_repositories, -> { where fork: false }, anonymous_class: Repository
  has_many :open_source_repositories, -> { where fork: false, private: false }, anonymous_class: Repository
  has_many :dependencies, through: :open_source_repositories
  has_many :favourite_projects, -> { group('projects.id').order("COUNT(projects.id) DESC, projects.rank DESC NULLS LAST") }, through: :dependencies, source: :project
  has_many :all_dependent_repos, -> { group('repositories.id') }, through: :favourite_projects, source: :repository
  has_many :contributed_repositories, -> { Repository.source.open_source }, through: :contributions, source: :repository
  has_many :contributors, -> { group('repository_users.id').order("sum(contributions.count) DESC") }, through: :open_source_repositories, source: :contributors
  has_many :fellow_contributors, -> (object){ where.not(id: object.id).group('repository_users.id').order("COUNT(repository_users.id) DESC") }, through: :contributed_repositories, source: :contributors
  has_many :projects, through: :open_source_repositories
  has_many :identities

  has_many :issues, primary_key: :uuid

  validates :login, uniqueness: {scope: :host_type}, if: lambda { self.login_changed? }
  validates :uuid, uniqueness: {scope: :host_type}, if: lambda { self.uuid_changed? }
  validates :uuid, presence: true

  after_commit :async_sync, on: :create

  scope :visible, -> { where(hidden: false) }
  scope :with_login, -> { where("repository_users.login <> ''") }
  scope :host, lambda{ |host_type| where('lower(repository_users.host_type) = ?', host_type.try(:downcase)) }

  delegate :avatar_url, :repository_url, :top_favourite_projects, :top_contributors,
           :to_s, :to_param, :github_id, to: :repository_owner

  def repository_owner
    RepositoryOwner::Gitlab
    @repository_owner ||= RepositoryOwner.const_get(host_type.capitalize).new(self)
  end

  def github_id
    uuid
  end

  def meta_tags
    {
      title: "#{self} on #{host_type}",
      description: "#{host_type} repositories created and contributed to by #{self}",
      image: avatar_url(200)
    }
  end

  def open_source_contributions
    contributions.joins(:repository).where("repositories.fork = ? AND repositories.private = ?", false, false)
  end

  def org?
    false
  end

  def github_client
    AuthToken.client
  end

  def async_sync
    RepositoryUpdateUserWorker.perform_async(self.login)
  end

  def sync
    download_from_github
    download_orgs
    download_repos
    update_attributes(last_synced_at: Time.now)
  end

  def download_from_github
    download_from_github_by(uuid)
  end

  def download_from_github_by_login
    download_from_github_by(login)
  end

  def download_from_github_by(id_or_login)
    RepositoryUser.create_from_github(github_client.user(id_or_login))
  rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
    nil
  end

  def download_orgs
    github_client.orgs(login).each do |org|
      RepositoryCreateOrgWorker.perform_async(org.login)
    end
    true
  rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
    nil
  end

  def download_repos
    AuthToken.client.search_repos("user:#{login}").items.each do |repo|
      Repository.create_from_hash repo.to_hash
    end

    true
  rescue *RepositoryHost::Github::IGNORABLE_EXCEPTIONS
    nil
  end

  def self.create_from_github(repository_user)
    user = nil
    user_by_id = RepositoryUser.host('GitHub').find_by_uuid(repository_user.id)
    user_by_login = RepositoryUser.host('GitHub').where("lower(login) = ?", repository_user.login.try(:downcase)).first
    if user_by_id # its fine
      if user_by_id.login.try(:downcase) == repository_user.login.downcase && user_by_id.user_type == repository_user.type
        user = user_by_id
      else
        if user_by_login && !user_by_login.download_from_github
          user_by_login.destroy
        end
        user_by_id.login = repository_user.login
        user_by_id.user_type = repository_user.type
        user_by_id.save!
        user = user_by_id
      end
    elsif user_by_login # conflict
      if user_by_login.download_from_github_by_login
        user = user_by_login if user_by_login.uuid == repository_user.id
      end
      user_by_login.destroy if user.nil?
    end
    if user.nil?
      user = RepositoryUser.create!(uuid: repository_user.id, login: repository_user.login, user_type: repository_user.type, host_type: 'GitHub')
    end
    user.update(repository_user.to_hash.slice(:name, :company, :blog, :location, :email, :bio))
    user
  end
end
