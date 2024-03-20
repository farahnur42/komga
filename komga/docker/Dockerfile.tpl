FROM --platform=linux/amd64 ubuntu:22.04 as temurin-build
ARG DEBIAN_FRONTEND=noninteractive
RUN  apt-get update \
  && apt-get install -qq -u --no-install-recommends \
    software-properties-common \
    dirmngr \
    gpg-agent \
    coreutils \
  && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0x219BD9C9 \
  && add-apt-repository 'deb http://repos.azulsystems.com/ubuntu stable main' \
  && apt-get update \
  && apt-get -y upgrade \
  && apt-get install -qq -y --no-install-recommends \
    ant \
    ant-contrib \
    autoconf \
    ca-certificates \
    cmake \
    cpio \
    curl \
    file \
    git \
    libasound2-dev \
    libcups2-dev \
    libelf-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libx11-dev \
    libxext-dev \
    libxi-dev \
    libxrandr-dev \
    libxrender-dev \
    libxt-dev \
    libxtst-dev \
    libjpeg-dev \
    make \
    perl \
    ssh \
    systemtap-sdt-dev \
    unzip \
    wget \
    zip \
    ccache \
    g++ \
    gcc \
  && rm -rf /var/lib/apt/lists/*
ARG BUILD_DIR=/build
RUN git clone https://github.com/adoptium/temurin-build ${BUILD_DIR}
WORKDIR ${BUILD_DIR}
USER root
RUN sh -c "mkdir -p /usr/lib/jvm/jdk20 && wget 'https://api.adoptium.net/v3/binary/latest/20/ga/linux/x64/jdk/hotspot/normal/adoptium?project=jdk' -O - | tar xzf - -C /usr/lib/jvm/jdk20 --strip-components=1"
RUN ln -sf /usr/lib/jvm/jdk20/bin/java /usr/bin/java && \
    ln -sf /usr/lib/jvm/jdk20/bin/javac /usr/bin/javac && \
    ln -sf /usr/lib/jvm/jdk20/bin/keytool /usr/bin/keytool
RUN ./makejdk-any-platform.sh -r https://github.com/adoptium/jdk21u -t jdk-21.0.2+13_adopt -u 2 -B 13 -p $(nproc) --create-jre-image --custom-cacerts false \
    -C "--build=x86_64-pc-linux-gnu --openjdk-target=x86_64-pc-linux-gnu --with-libjpeg=system --with-num-cores=$(nproc)" jdk21u

FROM --platform=linux/amd64 ubuntu:22.04 as temurin
ENV JAVA_VERSION jdk-21.0.2+13
ENV JAVA_HOME /opt/java/openjdk
ENV PATH $JAVA_HOME/bin:$PATH
COPY --from=temurin-build /build/workspace/target/OpenJDK-jre.tar.gz /tmp/openjdk.tar.gz
RUN set -eux; \
    mkdir -p "$JAVA_HOME"; \
    tar --extract \
        --file /tmp/openjdk.tar.gz \
        --directory "$JAVA_HOME" \
        --strip-components 1 \
        --no-same-owner \
    ; \
    rm -f /tmp/openjdk.tar.gz ${JAVA_HOME}/lib/src.zip; \
    # https://github.com/docker-library/openjdk/issues/331#issuecomment-498834472
    find "$JAVA_HOME/lib" -name '*.so' -exec dirname '{}' ';' | sort -u > /etc/ld.so.conf.d/docker-openjdk.conf; \
    ldconfig; \
    # https://github.com/docker-library/openjdk/issues/212#issuecomment-420979840
    # https://openjdk.java.net/jeps/341
    java -Xshare:dump;

FROM --platform=linux/amd64 ubuntu:22.04 as libjxl
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ENV CC=clang CXX=clang++ BUILD_DIR=/app/build
RUN apt update -y && apt install -y cmake clang doxygen graphviz git g++ extra-cmake-modules pkg-config \
    libgif-dev libjpeg-dev ninja-build libgoogle-perftools-dev qt6-base-dev libwebp-dev libbrotli-dev libpng-dev \
    asciidoc debhelper libgdk-pixbuf2.0-dev libgimp2.0-dev libgmock-dev libavif-dev libopenexr-dev xdg-utils xmlto \
    libgtest-dev libbenchmark-dev libbenchmark-tools clang-format clang-tidy curl parallel gcovr devscripts && apt -y autoremove && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/farahnur42/libjxl -b v0.10.2-jpegli --recursive --shallow-submodules /app
VOLUME /app/build
WORKDIR /app
USER root
## Build and install highway first, then build jxl debs
RUN ./ci.sh debian_build highway && dpkg -i ./build/debs/libhwy-dev*.deb && ./ci.sh debian_build jpeg-xl

FROM eclipse-temurin:17-jre as builder
ARG JAR={{distributionArtifactFile}}
COPY assembly/* /
RUN java -Djarmode=layertools -jar ${JAR} extract

# amd64 builder: uses ubuntu:22.04, as libjxl is not available on more recent versions
FROM --platform=linux/amd64 ubuntu:22.04 as build-amd64
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=temurin $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"
ARG LIBJXL_VERSION=0.10.2
COPY --from=libjxl /app/build/debs/*.deb /
WORKDIR /
RUN apt -y update && \
    apt -y install ca-certificates locales software-properties-common wget libwebp-dev libarchive-dev && \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen en_US.UTF-8 && \
    add-apt-repository -y ppa:strukturag/libheif && \
    add-apt-repository -y ppa:strukturag/libde265 && \
    apt -y update && apt install -y libheif-dev && \
    apt -y install ./libhwy-dev*.deb ./jxl_${LIBJXL_VERSION}_amd64.deb ./libjxl_${LIBJXL_VERSION}_amd64.deb ./libjxl-dev_${LIBJXL_VERSION}_amd64.deb && \
    rm *.deb && \
    apt -y remove wget software-properties-common && apt -y autoremove && rm -rf /var/lib/apt/lists/*

# arm64 builder: uses ubuntu23.10 which has libheif 1.16
FROM --platform=linux/arm64 ubuntu:23.10 as build-arm64
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=eclipse-temurin:21-jre $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"
RUN apt -y update && \
    apt -y install ca-certificates locales libheif-dev libwebp-dev libarchive-dev && \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen en_US.UTF-8

# arm builder: uses temurin-17, as arm32 support was dropped in JDK 21
FROM eclipse-temurin:17-jre as build-arm

FROM build-${TARGETARCH} AS runner
VOLUME /tmp
VOLUME /config
WORKDIR /app
COPY --from=builder dependencies/ ./
COPY --from=builder spring-boot-loader/ ./
COPY --from=builder snapshot-dependencies/ ./
COPY --from=builder application/ ./
ENV KOMGA_CONFIGDIR="/config"
ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'
ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/lib/x86_64-linux-gnu"
ENTRYPOINT ["java", "--enable-preview", "--enable-native-access=ALL-UNNAMED", "org.springframework.boot.loader.launch.JarLauncher", "--spring.config.additional-location=file:/config/"]
EXPOSE 25600
LABEL org.opencontainers.image.source="https://github.com/farahnur42/komga"
