require 'time'
require 'graphql/client'
require 'graphql/client/http'

module GitHubAPI
  HTTP = GraphQL::Client::HTTP.new('https://api.github.com/graphql') do
    def headers(context)
      { Authorization: "bearer #{ENV['GITHUB_TOKEN']}" }
    end
  end

  Schema = GraphQL::Client.load_schema(HTTP)

  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  CommitContributionFragment = <<-'GRAPHQL'
    contributions {
      totalCount
    }
  GRAPHQL

  PullRequestContributionFragment = <<-'GRAPHQL'
    contributions(first: 100) {
      totalCount
      nodes {
        occurredAt
        pullRequest {
          number
          title
          url
        }
      }
    }
  GRAPHQL

  IssueContributionFragment = <<-'GRAPHQL'
    contributions(first: 100) {
      totalCount
      nodes {
        occurredAt
        issue {
          number
          title
          url
        }
      }
    }
  GRAPHQL

  RepositoryFragment = <<-'GRAPHQL'
    repository {
      nameWithOwner
      owner {
        login
      }
      description
      openGraphImageUrl
      isArchived
      isDisabled
      isLocked
      isPrivate
      collaborators(query: $login) {
        edges {
          permission
        }
      }
      stargazers(first: 0) {
        totalCount
      }
      languages(first: 10, orderBy: { field: SIZE, direction: DESC }) {
        totalSize
        edges {
          size
          node {
            color
            name
          }
        }
      }
      repositoryTopics(first: 10) {
        nodes {
          topic {
            name
          }
          url
        }
      }
      url
    }
  GRAPHQL

  ContributingRepositoryQuery = Client.parse <<-"GRAPHQL"
    query($login: String!, $from: DateTime!, $to: DateTime!) {
      user(login: $login) {
        contributionsCollection(
          from: $from
          to: $to
        ) {
          commitContributionsByRepository(maxRepositories: 100) {
            #{CommitContributionFragment}
            #{RepositoryFragment}
          }
          pullRequestContributionsByRepository(maxRepositories: 100) {
            #{PullRequestContributionFragment}
            #{RepositoryFragment}
          }
          pullRequestReviewContributionsByRepository(maxRepositories: 100) {
            #{PullRequestContributionFragment}
            #{RepositoryFragment}
          }
          issueContributionsByRepository(maxRepositories: 100) {
            #{IssueContributionFragment}
            #{RepositoryFragment}
          }
        }
      }
    }
  GRAPHQL

  def self.role_of_repository(user, repository)
    if repository.owner.login == user
      'owner'
    elsif repository.collaborators && repository.collaborators.edges[0]
      case repository.collaborators.edges[0].permission
      when 'ADMIN' then
        'maintainer'
      when 'MAINTAIN' then
        'maintainer'
      when 'WRITE' then
        'collaborator'
      else
        'contributor'
      end
    else
      'contributor'
    end
  end

  def self.repository_to_hash(user, repository)
    size = repository.languages.total_size
    size = 1 if size <= 0
    {
      'name' =>        repository.name_with_owner,
      'description' => repository.description,
      'url' =>         repository.url,
      'image_url' =>   repository.open_graph_image_url,
      'is_private' =>  repository.is_private,
      'is_active' =>   ![
        repository.is_archived,
        repository.is_disabled,
        repository.is_locked,
      ].any?,
      'role' =>        self.role_of_repository(user, repository),
      'stargazers' =>  repository.stargazers.total_count,
      'languages' =>   repository.languages.edges.map do |l|
        {
          'name' =>     l.node.name,
          'color' =>    l.node.color,
          'size' =>     l.size,
          'coverage' => (l.size * 1.0 / size * 100).to_i,
        }
      end,
      'topics' =>      repository.repository_topics.nodes.map do |t|
        {
          'name' => t.topic.name,
          'url' =>  t.url,
        }
      end,
    }
  end

  def self.merge_repos(repo1, repo2)
    repo1.merge!(repo2) do |key, old, new|
      if key == 'contributions'
        old.merge!(new) do |key1, old1, new1|
          old1 + new1
        end
      else
        old
      end
    end
  end

  def self.repositories(user, from: from=nil, to: to=nil)
    to ||= Time.now
    from, to = to, from if from && to < from
    repos = {}

    loop do
      t = to - 60 * 60 * 24 * 365 + 1
      t = from if from && t < from
      result = GitHubAPI::Client.query(
        ContributingRepositoryQuery,
        variables: {
          login: user,
          from: t.iso8601,
          to: to.iso8601,
        }
      )
      unless result.data&.user && result.data&.user&.contributions_collection
        result.errors.all.each do |field, err|
          STDERR.puts("#{field}: #{err.inspect}")
        end
        break
      end

      contributions = result.data.user.contributions_collection

      contributions.commit_contributions_by_repository.each do |c|
        repo = self.repository_to_hash(user, c.repository).merge(
          {
            'contributions' => {
              'commits' => c.contributions.total_count,
            }
          }
        )
        repo['contributions']['details'] ||= []
        name = repo['name']
        repos[name] = self.merge_repos(repos[name] || {}, repo)
      end

      contributions.pull_request_contributions_by_repository.each do |c|
        repo = self.repository_to_hash(user, c.repository).merge(
          {
            'contributions' => {
              'pull_requests' => c.contributions.total_count,
            }
          }
        )
        repo['contributions']['details'] ||= []
        repo['contributions']['details'] += c.contributions.nodes.map do |c|
          {
            'type'        => 'pull-request',
            'url'         => c.pull_request.url,
            'title'       => c.pull_request.title,
            'occurred_at' => c.occurred_at,
            'number'      => c.pull_request.number,
          }
        end
        name = repo['name']
        repos[name] = self.merge_repos(repos[name] || {}, repo)
      end

      contributions.pull_request_review_contributions_by_repository.each do |c|
        repo = self.repository_to_hash(user, c.repository).merge(
          {
            'contributions' => {
              'reviews' => c.contributions.total_count,
            }
          }
        )
        repo['contributions']['details'] ||= []
        repo['contributions']['details'] += c.contributions.nodes.map do |c|
          {
            'type'        => 'review',
            'url'         => c.pull_request.url,
            'title'       => c.pull_request.title,
            'occurred_at' => c.occurred_at,
            'number'      => c.pull_request.number,
          }
        end
        name = repo['name']
        repos[name] = self.merge_repos(repos[name] || {}, repo)
      end

      contributions.issue_contributions_by_repository.each do |c|
        repo = self.repository_to_hash(user, c.repository).merge(
          {
            'contributions' => {
              'issues' => c.contributions.total_count,
            }
          }
        )
        repo['contributions']['details'] ||= []
        repo['contributions']['details'] += c.contributions.nodes.map do |c|
          {
            'type'        => 'issue',
            'url'         => c.issue.url,
            'title'       => c.issue.title,
            'occurred_at' => c.occurred_at,
            'number'      => c.issue.number,
          }
        end
        name = repo['name']
        repos[name] = self.merge_repos(repos[name] || {}, repo)
      end

      size = contributions.commit_contributions_by_repository.size +
             contributions.pull_request_contributions_by_repository.size +
             contributions.pull_request_review_contributions_by_repository.size +
             contributions.issue_contributions_by_repository.size
      break if size <= 0

      to = t - 1
      break if from && to < from
    end

    repos.values.select do |r|
      r['is_active'] && !r['is_private']
    end.sort do |a, b|
      b['stargazers'] <=> a['stargazers']
    end
  end
end
