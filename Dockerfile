# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage - compile and package the Spring Boot fat jar with the Gradle
# wrapper so the toolchain matches the project (Java 21, Spring Boot 4).
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS build
WORKDIR /workspace

# Copy the wrapper and build scripts first so dependency resolution is cached
# independently of source changes.
COPY gradlew settings.gradle build.gradle ./
COPY gradle ./gradle
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies || true

# Copy sources and build the jar (tests run in CI, skipped here for image speed).
COPY src ./src
RUN ./gradlew --no-daemon clean bootJar -x test

# ---------------------------------------------------------------------------
# Runtime stage - minimal JRE, non-root user, single layered jar.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre
WORKDIR /app

# Run as an unprivileged user (least privilege inside the container).
RUN groupadd --system spring && useradd --system --gid spring spring
USER spring

COPY --from=build /workspace/build/libs/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
