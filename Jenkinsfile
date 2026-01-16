pipeline {
    agent any
    environment {
        SCANNER_HOME = tool 'sonar-scanner'
    }

    stages {
        stage('Clean Workspace') {
            steps {
                cleanWs()
            }
        }

        stage('Checkout Code') {
            steps {
                git branch: 'main', changelog: false, poll: false, url: 'https://github.com/17J/K8sShield-Enterprise.git'
            }
        }

        stage('Gitleaks Secret Scanning') {
            steps {
                sh 'gitleaks detect --no-git --verbose --report-format json --report-path gitleaks-report.json || true'
                archiveArtifacts artifacts: 'gitleaks-report.json', allowEmptyArchive: true
            }
        }

        stage('Install Tools && Create Kind Cluster ') {
            steps {
                dir("${WORKSPACE}/scripts/") {
                    sh '''
                        bash install-prereqs.sh
                        sleep 10
                        bash setup-cluster-and-policy.sh
                        sleep 30
                    '''
                }
            }
        }

        stage('Snyk SCA Scan') {
            steps {
                withCredentials([string(credentialsId: 'snyk-cred', variable: 'SNYK_TOKEN')]) {
                    sh '''
                        snyk auth $SNYK_TOKEN
                        snyk test --severity-threshold=high --json-file-output=snyk-report.json || true
                    '''
                    archiveArtifacts artifacts: 'snyk-report.json', allowEmptyArchive: true
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('sonar') {
                    sh '''
                        $SCANNER_HOME/bin/sonar-scanner \
                        -Dsonar.projectName=k8sshield \
                        -Dsonar.projectKey=k8sshield \
                        -Dsonar.sources=.
                    '''
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Trivy FS Scan') {
            steps {
                sh 'trivy fs --severity HIGH,CRITICAL --format json -o trivy-report.json .'
                archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true
            }
        }

        stage('Deploy Manifest Files in Kind') {
            steps {
                dir("${WORKSPACE}/k8s-deploy/") {
                    sh '''
                        kubectl create ns two-tier-app
                        kubectl apply -f backend-redis-ds.yml 
                        kubectl apply -f frontend-nginx-ds.yml
                        kubectl apply -f ingress.yml
                        kubectl apply -f network-policy.yml
                        kubectl apply -f rbac.yml
                    '''
                }
            }
        }
        stage('Monitoring Setup') {
            steps {
                dir("${WORKSPACE}/monitoring/") {
                    sh '''
                        kubectl create ns monitoring
                        bash setup-monitoring.sh
                        sleep 60
                        kubectl apply -f nginx-servicemonitor.yml
                    '''
                }
            }
        }
        stage('Backup & Disaster Recovery') {
            steps {
                dir("${WORKSPACE}/backup/") {
                    sh '''
                        bash backup.sh
                        sleep 60
                        kubectl get all -A
                    '''
                }
            }
        }
    }
	
	
	post {
        always {
            echo "Pipeline execution completed"
        }
        success {
            echo "✅ DevSecOps Pipeline: SUCCESS"
            // Add Slack/Email notification here if needed
        }
        failure {
            echo "❌ DevSecOps Pipeline: FAILED"
            // Add Slack/Email notification here if needed
        }
    }
}