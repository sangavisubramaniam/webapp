package com.example.web_app.repo;
import com.example.web_app.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;
//import org.springframework.boot.autoconfigure.security.SecurityProperties.User;
import java.util.Optional;
@Repository
public interface UserRepo extends JpaRepository <User, Long>{
    Optional<User> findByUsername(String username);
} 
