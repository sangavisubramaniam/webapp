pipeline {
    agent {
        label 'jenkins-agent'
    }

    parameters {
        booleanParam(
            name: 'releaseBuild',
            defaultValue: false,
            description: 'Run SonarQube analysis for release builds'
        )
    }

    environment {
        SERVICE_NAME         = 'webapp'      // used for the Helm archive name in Nexus

        // ---- Docker Hub: images go to docker.io/<namespace>/<repo>:<build number> ----
        DOCKERHUB_NAMESPACE  = 'sangvisubramaniam'
        DOCKERHUB_REPO       = 'sang'

        SONARQUBE_SERVER = 'SonarQube'

        // Jenkins reaches Nexus by its compose service name
        NEXUS_URL        = 'http://nexus:8081'
        NEXUS_HELM_REPO  = 'helm-raw'
    }

    stages {

        stage('Checkout') {
            steps {
                echo 'Cloning microservice repository'

                checkout scmGit(
                    branches: [[name: '*/main']],
                    extensions: [],
                    userRemoteConfigs: [[
                        credentialsId: 'Git_Sang_Cred',
                        url: 'https://github.com/sangavisubramaniam/webapp.git'
                    ]]
                )
            }
        }

        stage('Build') {
            steps {
                echo 'Building microservice with Maven'

                sh 'mvn clean install'

                script {
                    env.IMAGE_NAME =
                        "${env.DOCKERHUB_NAMESPACE}/${env.DOCKERHUB_REPO}:${env.BUILD_NUMBER}"
                }

                echo "Building Docker image: ${env.IMAGE_NAME}"

                sh '''
                    docker build \
                        -t "$IMAGE_NAME" \
                        -f Dockerfile \
                        .
                '''
            }
        }

        stage('Run SonarQube') {
            when {
                expression {
                    params.releaseBuild == true
                }
            }

            steps {
                echo 'Running SonarQube analysis for release build'

                withSonarQubeEnv("${SONARQUBE_SERVER}") {
                    sh 'mvn sonar:sonar'
                }
            }
        }

        stage('Push to Docker Hub') {
            steps {
                echo 'Pushing Docker image to Docker Hub'

                withCredentials([
                    usernamePassword(
                        credentialsId: 'DockerHub_Creds',
                        usernameVariable: 'DH_USER',
                        passwordVariable: 'DH_TOKEN'
                    )
                ]) {
                    sh '''
                        set +x

                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin

                        docker push "$IMAGE_NAME"

                        docker logout
                    '''
                }
            }
        }

        stage('Pull and Verify') {
            steps {
                echo 'Removing local copy, then pulling the image back from Docker Hub'

                sh '''
                    docker rmi "$IMAGE_NAME"
                    docker pull "$IMAGE_NAME"
                    docker image inspect "$IMAGE_NAME" --format 'Pulled {{.RepoTags}} ({{.Size}} bytes)'
                '''
            }
        }

        stage('Package and Upload Helm to Nexus') {
            steps {
                echo 'Packaging Helm directory'

                sh '''
                    set -eu

                    test -d helm

                    tar -czf "${SERVICE_NAME}-${BUILD_NUMBER}-helm.tar.gz" helm/
                '''

                echo 'Uploading Helm archive to Nexus'

                withCredentials([
                    usernamePassword(
                        credentialsId: 'Nexus_Creds',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set +x

                        curl --fail --show-error \
                            --user "$NEXUS_USER:$NEXUS_PASSWORD" \
                            --upload-file "${SERVICE_NAME}-${BUILD_NUMBER}-helm.tar.gz" \
                            "${NEXUS_URL}/repository/${NEXUS_HELM_REPO}/${SERVICE_NAME}/${SERVICE_NAME}-${BUILD_NUMBER}-helm.tar.gz"
                    '''
                }
            }
        }
    }

    post {
        success {
            echo 'CI pipeline completed successfully'
        }

        failure {
            echo 'CI pipeline failed. Check the stage logs.'
        }

        always {
            // free local disk: remove the image
            sh 'docker rmi "$IMAGE_NAME" || true'
            echo 'CI pipeline execution finished'
        }
    }
}
